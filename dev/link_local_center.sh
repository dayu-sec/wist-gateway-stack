#!/usr/bin/env bash
# 把**本机网关栈**接到**本机中心**（dev）。
#
# gwlinkd 是网关**宿主侧**的容器外常驻（CR-003），随网关走 —— 所以本脚本在 gateway-stack。
# 两条路：
#   快速路（默认）      脚本直接建/复用中心实例 + 取一次性接入券 + 起 gwlinkd（不经网关页）。
#   页面路 --via-gateway 配好 gwlinkd 让它**轮询网关**「链接上级」页提交的接入请求（真产品路径）。
#
# 页面路的关键：gwlinkd 只有配了 `gateway_self_endpoint` 才会去拉网关；且**只在未注册（首跑）时拉**。
# 所以页面路用独立 home（`.run/gwlinkd-gateway`），并要求它是未注册状态 —— 已注册就跑不到拉取那步。
#
# 前提：本机中心在跑（默认 https://127.0.0.1:3100，wist-center-stack/dev 起的那个，TLS 默认开）。
#
# 用法：
#   ./dev/link_local_center.sh                 # 快速路：建/复用实例并起 gwlinkd
#   ./dev/link_local_center.sh --via-gateway   # 页面路：起 gwlinkd 等网关页提交接入请求
#   ./dev/link_local_center.sh --stop          # 停 gwlinkd
#
# 可覆盖 env：
#   WIST_CENTER_ADDR            中心地址（默认 https://127.0.0.1:3100）
#   WIST_CENTER_CONFIG          中心配置（读 admin token；默认 ~/.wist-center/wist-center.toml）
#   WIST_CENTER_TLS_DIR         中心 TLS 目录（读 CA-S；默认 ~/.wist-center/tls）
#   WIST_GWLINKD_HOME           gwlinkd 配置 + state 目录（默认：快速路 .run/gwlinkd；页面路 .run/gwlinkd-gateway）
#   GATEWAY_ID                  中心侧实例名（快速路默认 gw-local；页面路须与页面接入物里的一致）
#   WIST_GATEWAY_SELF_ENDPOINT  页面路：网关环回面（默认 https://127.0.0.1:3000）
#   WIST_GATEWAY_SELF_CA        页面路：环回面信任锚（默认 dev/configs/gateway/state/gateway-ca.crt.pem）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

GWLINKD_CRATE="${WIST_GWLINKD_CRATE:-${ROOT_DIR}/wist-gwlinkd}"
CENTER_ADDR="${WIST_CENTER_ADDR:-https://127.0.0.1:3100}"
CENTER_CONFIG="${WIST_CENTER_CONFIG:-${HOME}/.wist-center/wist-center.toml}"
CA_CERT="${WIST_CENTER_CA_CERT:-${WIST_CENTER_TLS_DIR:-${HOME}/.wist-center/tls}/ca.crt.pem}"
GATEWAY_ID="${GATEWAY_ID:-gw-local}"
GATEWAY_SELF_ENDPOINT="${WIST_GATEWAY_SELF_ENDPOINT:-https://127.0.0.1:3000}"
GATEWAY_SELF_CA="${WIST_GATEWAY_SELF_CA:-${STACK_ROOT}/dev/configs/gateway/state/gateway-ca.crt.pem}"

die() { echo "错误：$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

MODE=fast
case "${1:-}" in
  "" | start | --start | fast) MODE=fast ;;
  gateway | --via-gateway | --gateway) MODE=gateway ;;
  stop | --stop) MODE=stop ;;
  -h | --help) MODE=help ;;
  *) die "未知参数：$1（可用：无 / --via-gateway / --stop）" ;;
esac

if [[ -n "${WIST_GWLINKD_HOME:-}" ]]; then
  GWLINKD_HOME="${WIST_GWLINKD_HOME}"
elif [[ "${MODE}" == "gateway" ]]; then
  GWLINKD_HOME="${STACK_ROOT}/.run/gwlinkd-gateway"
else
  GWLINKD_HOME="${STACK_ROOT}/.run/gwlinkd"
fi
GWLINKD_CONFIG="${GWLINKD_HOME}/gwlinkd.toml"
GWLINKD_LOG="${GWLINKD_HOME}/gwlinkd.log"
GWLINKD_STATE="${GWLINKD_HOME}/state"
GWLINKD_PID_FILE="${GWLINKD_HOME}/gwlinkd.pid"

help() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# 读中心配置里的 `admin_token = "..."`。
admin_token() {
  python3 - "${CENTER_CONFIG}" <<'PY'
import re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    match = re.search(r'^\s*admin_token\s*=\s*"(.*)"\s*$', handle.read(), re.M)
print(match.group(1) if match else "")
PY
}

# 在跑的 gwlinkd pid（pidfile 优先，再 pgrep 兜底）。
gwlinkd_pid() {
  if [[ -f "${GWLINKD_PID_FILE}" ]]; then
    local p
    p="$(cat "${GWLINKD_PID_FILE}" 2>/dev/null || true)"
    kill -0 "${p}" 2>/dev/null && { echo "${p}"; return; }
  fi
  pgrep -f 'wist-gwlinkd run' 2>/dev/null | head -1 || true
}

stop_gwlinkd() {
  local pid
  pid="$(gwlinkd_pid)"
  if [[ -n "${pid}" ]]; then
    kill "${pid}" 2>/dev/null || true
    echo "已停止 wist-gwlinkd（pid=${pid}）"
  else
    echo "wist-gwlinkd 未在运行"
  fi
  rm -f "${GWLINKD_PID_FILE}"
}

build_gwlinkd() {
  if command -v cargo >/dev/null 2>&1; then
    echo "== 构建 wist-gwlinkd（增量）=="
    cargo build --manifest-path "${GWLINKD_CRATE}/Cargo.toml"
  fi
}

# 起 gwlinkd（后台）。$1 = 一次性接入券（空 = 不设 env，走页面/已存凭据）。
launch_gwlinkd() {
  local bin="${GWLINKD_CRATE}/target/debug/wist-gwlinkd"
  local token="${1:-}"
  [[ -x "${bin}" ]] || die "缺 gwlinkd 二进制：${bin}"
  echo "== 启动 wist-gwlinkd（连 ${CENTER_ADDR}）=="
  # 注意：**空串不能当 env 传** —— link_token_from_env 会把「已设但空」也当成有券。
  if [[ -n "${token}" ]]; then
    WIST_GWLINKD_CONFIG="${GWLINKD_CONFIG}" WIST_GWLINKD_LINK_TOKEN="${token}" \
      nohup "${bin}" run >"${GWLINKD_LOG}" 2>&1 &
  else
    WIST_GWLINKD_CONFIG="${GWLINKD_CONFIG}" \
      nohup "${bin}" run >"${GWLINKD_LOG}" 2>&1 &
  fi
  local newpid=$!
  echo "${newpid}" >"${GWLINKD_PID_FILE}"
  sleep 2
  if kill -0 "${newpid}" 2>/dev/null; then
    echo "  gwlinkd 在跑（pid=${newpid}）。最近日志："
    tail -n 10 "${GWLINKD_LOG}" || true
  else
    echo "  gwlinkd 未存活，日志：${GWLINKD_LOG}" >&2
    tail -n 20 "${GWLINKD_LOG}" >&2 || true
    return 1
  fi
}

# ── 快速路：脚本直接建/复用中心实例 + 取券 + 起 gwlinkd ──────────────────────
start_fast() {
  require_cmd python3
  require_cmd curl
  build_gwlinkd

  # 已注册且中心一致 → 复用；否则（端点变了 / 上次注册半途）重置身份后重建。
  GWLINKD_LINK=""
  if [[ -f "${GWLINKD_CONFIG}" ]]; then
    local have
    have="$(sed -n 's/^control_center_endpoint[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${GWLINKD_CONFIG}" | head -1)"
    if [[ -f "${GWLINKD_STATE}/credential.json" && "${have}" == "${CENTER_ADDR}" ]]; then
      echo "gwlinkd 已注册，复用 ${GWLINKD_CONFIG}（不新建实例）"
    else
      local why
      [[ -f "${GWLINKD_STATE}/credential.json" ]] && why="中心端点 ${have:-?} ≠ ${CENTER_ADDR}" || why="上次注册未完成（无客户端证书）"
      echo "gwlinkd 需要重新接入（${why}）→ 重置身份后重建"
      rm -rf "${GWLINKD_STATE}"
      rm -f "${GWLINKD_CONFIG}"
    fi
  fi

  if [[ ! -f "${GWLINKD_CONFIG}" ]]; then
    [[ -f "${CA_CERT}" ]] || die "找不到中心 CA：${CA_CERT}（中心以 TLS 起时才有）"
    local token
    token="$(admin_token)"
    [[ -n "${token}" ]] || die "读不到 admin token（${CENTER_CONFIG}）"
    mkdir -p "${GWLINKD_STATE}"
    # 建/复用：中心侧实例名由 gateway_name 派生（= 去空格的 GATEWAY_ID），重复 create → 409。
    echo "== 通过 admin API 建/复用网关实例（${GATEWAY_ID}）=="
    local resp gw state
    state="$(curl -sk "${CENTER_ADDR}/api/v1/admin/gateways/instances" \
      -H "authorization: Bearer ${token}" \
      | python3 -c "import json,sys;m=next((g for g in json.load(sys.stdin) if g['gateway_id']==sys.argv[1]),None);print(m['lifecycle_state'] if m else '')" "${GATEWAY_ID}" 2>/dev/null || true)"
    if [[ -n "${state}" ]]; then
      # 已置备（Running/Initializing/Failed）的实例，link-upstream 已从接入券切到**客户端证书**认人；
      # 中心没有「重置实例」的接口，本地身份又不在 → 只能换 id。
      if [[ "${state}" != "Provisioned" ]]; then
        die "中心实例 ${GATEWAY_ID} 已置备（lifecycle_state=${state}）：它的 link-upstream 已要求客户端证书，
     而本地身份不在（无法用接入券重连），中心侧也没有重置接口。
     换个名字重跑：GATEWAY_ID=${GATEWAY_ID}-dev ./dev/link_local_center.sh"
      fi
      gw="${GATEWAY_ID}"
      echo "  实例已存在且未置备，复用：${gw}"
    else
      resp="$(curl -sk -X POST "${CENTER_ADDR}/api/v1/admin/gateways/instances" \
        -H "authorization: Bearer ${token}" -H "content-type: application/json" \
        -d "{\"gateway_name\":\"${GATEWAY_ID}\",\"requested_by\":\"dev\"}")"
      gw="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['instance']['gateway_id'])" "${resp}" 2>/dev/null || true)"
      [[ -n "${gw}" ]] || die "创建网关实例失败：${resp}"
      echo "  新建实例：${gw}"
    fi
    local issued boot
    issued="$(curl -sk -X POST "${CENTER_ADDR}/api/v1/admin/gateways/${gw}/link-token" \
      -H "authorization: Bearer ${token}" -H "content-type: application/json" \
      -d '{"requested_by":"dev"}')"
    boot="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['install']['link_token'])" "${issued}" 2>/dev/null || true)"
    [[ -n "${boot}" ]] || die "生成接入券失败：${issued}"
    cat >"${GWLINKD_CONFIG}" <<EOF
control_center_endpoint = "${CENTER_ADDR}"
trust_bundle = "${CA_CERT}"
state_dir = "${GWLINKD_STATE}"
gateway_id = "${gw}"
EOF
    GWLINKD_LINK="${boot}"
    echo "  gwlinkd 配置：${GWLINKD_CONFIG}"
  fi

  launch_gwlinkd "${GWLINKD_LINK}"
}

# ── 页面路：gwlinkd 轮询网关「链接上级」页提交的接入请求 ─────────────────────
start_gateway_mode() {
  [[ -f "${CA_CERT}" ]] || die "找不到中心 CA：${CA_CERT}（中心以 TLS 起时才有）"
  [[ -f "${GATEWAY_SELF_CA}" ]] || die "找不到网关环回面信任锚：${GATEWAY_SELF_CA}（网关先跑过 dev/setup-domain.sh）"
  build_gwlinkd

  # 换实例（gateway_id 变了）→ 自动重置：页面路只在未注册（首跑）时拉，留着旧身份反而挡住。
  if [[ -f "${GWLINKD_CONFIG}" ]]; then
    local have
    have="$(sed -n 's/^gateway_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${GWLINKD_CONFIG}" | head -1)"
    if [[ -n "${have}" && "${have}" != "${GATEWAY_ID}" ]]; then
      echo "页面路 gwlinkd 之前是 ${have}，本次要接 ${GATEWAY_ID} → 重置本地身份"
      rm -rf "${GWLINKD_STATE}" "${GWLINKD_CONFIG}"
    fi
  fi

  mkdir -p "${GWLINKD_STATE}"
  if [[ -f "${GWLINKD_STATE}/credential.json" ]]; then
    echo "提示：${GWLINKD_HOME} 对 ${GATEWAY_ID} 已注册 —— gwlinkd 只在**未注册（首跑）**时拉页面请求，"
    echo "      不会再消费网关页的新提交。要重走页面接入："
    echo "      rm -rf ${GWLINKD_STATE} ${GWLINKD_CONFIG} && GATEWAY_ID=${GATEWAY_ID} ./dev/link_local_center.sh --via-gateway"
    echo
  fi

  cat >"${GWLINKD_CONFIG}" <<EOF
control_center_endpoint = "${CENTER_ADDR}"
trust_bundle = "${CA_CERT}"
state_dir = "${GWLINKD_STATE}"
gateway_id = "${GATEWAY_ID}"
gateway_self_endpoint = "${GATEWAY_SELF_ENDPOINT}"
gateway_self_ca = "${GATEWAY_SELF_CA}"
EOF
  echo "  gwlinkd 配置：${GWLINKD_CONFIG}（页面路：轮询 ${GATEWAY_SELF_ENDPOINT}）"
  echo "  在网关「链接上级」页粘贴接入链接（其 gateway_id 须为 ${GATEWAY_ID}）；gwlinkd 会拉取并接入。"
  echo

  launch_gwlinkd ""
}

case "${MODE}" in
  fast) start_fast ;;
  gateway) start_gateway_mode ;;
  stop) stop_gwlinkd ;;
  help) help ;;
esac
