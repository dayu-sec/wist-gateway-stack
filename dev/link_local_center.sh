#!/usr/bin/env bash
# 快速路：把**本机网关栈**接到**本机中心**（dev，省去页面「链接上级」/ 手搓 gwlinkd.toml）。
#
# gwlinkd 是**网关宿主侧**的容器外常驻（CR-003），随网关走 —— 所以本脚本在 gateway-stack。
# 它做四件事：
#   1. 构建本机的 wist-gwlinkd；
#   2. 调本机中心的 admin API：建/复用网关实例 + 取一次性接入券；
#   3. 写 <home>/gwlinkd.toml（中心 endpoint + CA-S + state_dir + gateway_id）；
#   4. 后台跑 gwlinkd：link-upstream → register（换客户端证书）→ 周期 status；此后走 mTLS。
#
# 前提：本机中心在跑（默认 https://127.0.0.1:3100，即 wist-center-stack/dev 起的那个，TLS 默认开）。
# 幂等：已注册且中心一致 → 复用、不新建实例；中心变了 / 上次注册半途 → 重置身份后重建；
# 实例已置备（中心侧）但本地身份丢失 → 拒绝并提示换 GATEWAY_ID（中心无重置接口）。
#
# 用法：
#   ./dev/link_local_center.sh          # 建/复用并起 gwlinkd
#   ./dev/link_local_center.sh --stop   # 停掉 gwlinkd
#
# 可覆盖 env：
#   WIST_CENTER_ADDR     中心地址（默认 https://127.0.0.1:3100）
#   WIST_CENTER_CONFIG   中心配置（读 admin token；默认 ~/.wist-center/wist-center.toml）
#   WIST_CENTER_TLS_DIR  中心 TLS 目录（读 CA-S；默认 ~/.wist-center/tls）
#   WIST_GWLINKD_HOME    gwlinkd 的配置 + state 目录（默认 <栈根>/.run/gwlinkd）
#   GATEWAY_ID           中心侧实例名（默认 gw-local）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

GWLINKD_CRATE="${WIST_GWLINKD_CRATE:-${ROOT_DIR}/wist-gwlinkd}"
CENTER_ADDR="${WIST_CENTER_ADDR:-https://127.0.0.1:3100}"
CENTER_CONFIG="${WIST_CENTER_CONFIG:-${HOME}/.wist-center/wist-center.toml}"
CA_CERT="${WIST_CENTER_CA_CERT:-${WIST_CENTER_TLS_DIR:-${HOME}/.wist-center/tls}/ca.crt.pem}"
GWLINKD_HOME="${WIST_GWLINKD_HOME:-${STACK_ROOT}/.run/gwlinkd}"
GWLINKD_CONFIG="${GWLINKD_HOME}/gwlinkd.toml"
GWLINKD_LOG="${GWLINKD_HOME}/gwlinkd.log"
GWLINKD_PID_FILE="${STACK_ROOT}/.run/gwlinkd.pid"
GATEWAY_ID="${GATEWAY_ID:-gw-local}"

die() {
  echo "错误：$*" >&2
  exit 1
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

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

start_gwlinkd() {
  require_cmd python3
  require_cmd curl

  local running
  running="$(gwlinkd_pid)"
  if [[ -n "${running}" ]]; then
    echo "wist-gwlinkd 已在运行（pid=${running}），复用。"
    echo "${running}" >"${GWLINKD_PID_FILE}"
    return 0
  fi

  # 1. 构建
  if command -v cargo >/dev/null 2>&1; then
    echo "== 构建 wist-gwlinkd（增量）=="
    cargo build --manifest-path "${GWLINKD_CRATE}/Cargo.toml"
  fi
  local bin="${GWLINKD_CRATE}/target/debug/wist-gwlinkd"
  [[ -x "${bin}" ]] || die "缺 gwlinkd 二进制：${bin}"

  # 2. 接入物：已注册且中心一致 → 复用；否则（端点变了先重置）建实例 + 取券 + 写配置。
  GWLINKD_LINK=""
  if [[ -f "${GWLINKD_CONFIG}" ]]; then
    local have
    have="$(sed -n 's/^control_center_endpoint[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${GWLINKD_CONFIG}" | head -1)"
    if [[ -f "${GWLINKD_HOME}/state/credential.json" && "${have}" == "${CENTER_ADDR}" ]]; then
      echo "gwlinkd 已注册，复用 ${GWLINKD_CONFIG}（不新建实例）"
    else
      # 换中心，或上次注册半途（配置写了、凭据没换到）二者都重置身份、重走接入。
      local why
      [[ -f "${GWLINKD_HOME}/state/credential.json" ]] && why="中心端点 ${have:-?} ≠ ${CENTER_ADDR}" || why="上次注册未完成（无客户端证书）"
      echo "gwlinkd 需要重新接入（${why}）→ 重置身份后重建"
      rm -rf "${GWLINKD_HOME}/state"
      rm -f "${GWLINKD_CONFIG}"
    fi
  fi

  if [[ ! -f "${GWLINKD_CONFIG}" ]]; then
    [[ -f "${CA_CERT}" ]] || die "找不到中心 CA：${CA_CERT}（中心以 TLS 起时才有）"
    local token
    token="$(admin_token)"
    [[ -n "${token}" ]] || die "读不到 admin token（${CENTER_CONFIG}）"
    mkdir -p "${GWLINKD_HOME}/state"
    # 建/复用：中心侧实例名由 gateway_name 派生（= 去空格的 GATEWAY_ID），重复 create → 409。
    # 所以先按 name 查一遍：在 → 复用（本地身份丢了也能续上）；不在 → create。
    echo "== 通过 admin API 建/复用网关实例（${GATEWAY_ID}）=="
    local resp gw state
    state="$(curl -sk "${CENTER_ADDR}/api/v1/admin/gateways/instances" \
      -H "authorization: Bearer ${token}" \
      | python3 -c "import json,sys;m=next((g for g in json.load(sys.stdin) if g['gateway_id']==sys.argv[1]),None);print(m['lifecycle_state'] if m else '')" "${GATEWAY_ID}" 2>/dev/null || true)"
    if [[ -n "${state}" ]]; then
      # 已置备（Running/Initializing/Failed）的实例，link-upstream 已从接入券切到**客户端证书**认人；
      # 中心没有「重置实例」的接口，本地身份又刚没了 → 只能换 id 或去中心侧重置。
      if [[ "${state}" != "Provisioned" ]]; then
        die "中心实例 ${GATEWAY_ID} 已置备（lifecycle_state=${state}）：它的 link-upstream 已要求客户端证书，
     而本地身份不在（无法用接入券重连），中心侧也没有重置接口。
     换个名字重跑：GATEWAY_ID=${GATEWAY_ID}-dev ./dev/link_local_center.sh
     （或先在中心侧清掉该实例再试）。"
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
state_dir = "${GWLINKD_HOME}/state"
gateway_id = "${gw}"
EOF
    GWLINKD_LINK="${boot}"
    echo "  gwlinkd 配置：${GWLINKD_CONFIG}"
  fi

  # 3. 跑
  echo "== 启动 wist-gwlinkd（连 ${CENTER_ADDR}）=="
  WIST_GWLINKD_CONFIG="${GWLINKD_CONFIG}" \
    WIST_GWLINKD_LINK_TOKEN="${GWLINKD_LINK}" \
    nohup "${bin}" run >"${GWLINKD_LOG}" 2>&1 &
  local newpid=$!
  echo "${newpid}" >"${GWLINKD_PID_FILE}"
  sleep 2
  if kill -0 "${newpid}" 2>/dev/null; then
    echo "  gwlinkd 在跑（pid=${newpid}）。最近日志："
    tail -n 6 "${GWLINKD_LOG}" || true
  else
    echo "  gwlinkd 未存活，日志：${GWLINKD_LOG}" >&2
    tail -n 20 "${GWLINKD_LOG}" >&2 || true
    return 1
  fi
}

case "${1:-}" in
  --stop | stop) stop_gwlinkd ;;
  "" | start | --start) start_gwlinkd ;;
  -h | --help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "未知参数：$1（可用：无 / --stop）" ;;
esac
