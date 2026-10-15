#!/usr/bin/env bash
# 断开本机网关与上级控制中心（Center）的连接（开发态）。
#
# **清理逻辑归 `wist-gwlinkd`**（与 link/`onboard` 同一个 owner，见 `wist-gwlinkd/src/unlink.rs`）：
# 「与 Center 的连接」= gwlinkd 手里的注册态（客户端证书 / 链接配置 / 注册券 / 身份 / 实例），
# 加上**现场态配置**里的一次性接入券 `link_token`。unlink 由 gwlinkd 自己删，本脚本只负责接线 ——
# **停掉 gwlinkd、调 `wist-gwlinkd unlink`、再把它起回**，不做任何文件手术。
#
#   * 不碰中心信任锚（trust_bundle 的 PEM）—— 它是中心的公开证书，不是连接；`--forget-center` 才删。
#   * 需先停 gwlinkd（运行中的常驻会不停写回凭据）；本脚本默认替你**停 → unlink → 再起回**，
#     所以 unlink 完组件仍在（回到「等待页面接入请求」），不会只剩个停着的常驻。
#
# **gwlinkd 归系统服务**（`dev/svc.sh` 已不管它）：停 / 起走服务管理器
# （`launchctl bootout|bootstrap system/<label>` / `systemctl stop|start wist-gwlinkd`），
# 它的 bin / config / pub 从**已装的服务定义**里读（与 `dev/install-gwlinkd-dev.sh` 同一口径）；
# 没有服务定义时退回「老的 nohup 形态」（dev 的 config+pidfile）—— 那种只停，不自动起回。
# 注：只处理**系统级**服务；`--user` 级服务的停/起不在本脚本范围内（装了的话请手工停它再跑 unlink）。
#
# 它**不**在 Center 侧注销这台网关（那是 center-stack 的事）：Center 那边实例仍在（lifecycle 已
# Initializing/Running）。想用**同一个 gateway_id** 再接入，得先在 Center 侧把它恢复成未初始化
# （Provisioned），否则 link-upstream 不再发 RegistToken、register 会失败；或干脆换一个新 gateway_id。
#
# 用法：
#   ./dev/unlink-center.sh [--dry-run] [--forget-center] [--no-restart]
#     ./dev/unlink-center.sh                   # 停 gwlinkd → unlink → 再起回 gwlinkd
#     ./dev/unlink-center.sh --dry-run         # 只看将做什么（不落盘；也不停/不起进程）
#     ./dev/unlink-center.sh --forget-center   # 连中心 CA（trust_bundle）也一并清掉
#     ./dev/unlink-center.sh --no-restart      # unlink 后**不**起回 gwlinkd（保持停止）
#
# 可覆盖 env：
#   WIST_GWLINKD_DEV_BIN=<path>        用哪个 gwlinkd 跑 unlink（默认：服务已装的那个 > 本地构建）
#   WIST_GWLINKD_DEV_CONFIG=<path>     主配置（默认取服务现有定义里的）
#   WIST_GWLINKD_DEV_PUB_CONFIG=<path> 现场态配置（同上口径）
#   DRY_RUN=1                          等价 --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# $WIST（crate 所在仓组根）—— 与 svc.sh 同一套解析（脚本可能落在 wist/ 组内，也可能与组件同级）。
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [[ -d "${ROOT_DIR}/wist/wist-gateway" ]]; then
  ROOT_DIR="${ROOT_DIR}/wist"
elif [[ -d "${ROOT_DIR}/../wist/wist-gateway" ]]; then
  ROOT_DIR="$(cd "${ROOT_DIR}/../wist" && pwd)"
fi
LOCAL_GWLINKD_BIN="${ROOT_DIR}/wist-gwlinkd/target/debug/wist-gwlinkd"

# 服务 / 发布态的固定落点（与 wist-gwlinkd 的 src/service/* 常量一致）。
SERVICE_NAME="wist-gwlinkd"
LAUNCHD_LABEL="com.dayu-sec.wist-gwlinkd"
CONF_ENV="WIST_GWLINKD_CONFIG"
PUBCFG_ENV="WIST_GWLINKD_PUB_CONFIG"
# 老的 nohup 形态（退役）留下的配置与 pidfile —— 只在「没有服务定义」时作兜底。
LEGACY_HOME="${STACK_ROOT}/dev/configs/gwlinkd"
LEGACY_CONFIG="${LEGACY_HOME}/gwlinkd.toml"
LEGACY_PIDFILE="${LEGACY_HOME}/gwlinkd.pid"
PUB_DEFAULT="${STACK_ROOT}/identity/gwlinkd/gwlinkd-pub.toml"

# 系统级服务要 root：脚本自己提权（别整个用 sudo 跑）。
SUDO="sudo"
DRY_RUN="${DRY_RUN:-0}"
FORGET_CENTER=0
NO_RESTART=0

case "$(uname -s)" in
  Darwin)
    PLATFORM="launchd"
    DEFINITION="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
    ;;
  Linux)
    PLATFORM="systemd"
    DEFINITION="/etc/systemd/system/${SERVICE_NAME}.service"
    ;;
  *) DEFINITION="" ;;
esac

die() {
  echo "错误：$*" >&2
  exit 1
}

note() {
  echo "  $*"
}

warn() {
  echo "  [warn] $*" >&2
}

# 干跑：只打印将执行的命令（`${SUDO}` 为空串时展开为空是「设了值」，`set -u` 下不报错）。
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '    [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

usage() {
  cat <<'EOF'
用法：./dev/unlink-center.sh [--dry-run] [--forget-center] [--no-restart]
      ./dev/unlink-center.sh                   # 停 gwlinkd → unlink → 再起回 gwlinkd
      ./dev/unlink-center.sh --dry-run         # 只看将做什么（不落盘；也不停/不起进程）
      ./dev/unlink-center.sh --forget-center   # 连中心 CA（trust_bundle）也一并清掉
      ./dev/unlink-center.sh --no-restart      # unlink 后**不**起回 gwlinkd（保持停止）
可覆盖 env：DRY_RUN=1（等价 --dry-run）
      WIST_GWLINKD_DEV_BIN / _CONFIG / _PUB_CONFIG（默认：服务现有定义 > 本地兜底）
EOF
}

for arg in "$@"; do
  case "${arg}" in
    -h | --help)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --forget-center)
      FORGET_CENTER=1
      ;;
    --no-restart)
      NO_RESTART=1
      ;;
    -*)
      usage >&2
      die "未知参数 ${arg}"
      ;;
    *)
      usage >&2
      die "不接受位置参数：${arg}"
      ;;
  esac
done

# ── 从「服务现有定义」里读 bin / config / pub（读不到才退回老的 nohup 形态那一套）──
# 为什么要读而不是猜：服务跑的就是这几条路径，unlink 必须清**同一份**注册态
# （state_dir / identity_dir 都由 config 决定），猜错就清了个不相干的目录。
DEFINITION_BIN=""
DEFINITION_CONF=""
DEFINITION_PUB=""
if [[ -n "${DEFINITION}" && -f "${DEFINITION}" ]]; then
  if [[ "${PLATFORM}" == "launchd" ]]; then
    if command -v plutil >/dev/null 2>&1; then
      DEFINITION_BIN="$(plutil -extract ProgramArguments.0 raw -o - "${DEFINITION}" 2>/dev/null || true)"
      DEFINITION_CONF="$(plutil -extract "EnvironmentVariables.${CONF_ENV}" raw -o - "${DEFINITION}" 2>/dev/null || true)"
      DEFINITION_PUB="$(plutil -extract "EnvironmentVariables.${PUBCFG_ENV}" raw -o - "${DEFINITION}" 2>/dev/null || true)"
    fi
  else
    DEFINITION_BIN="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "${DEFINITION}" 2>/dev/null | head -1 || true)"
    DEFINITION_CONF="$(sed -n "s/^Environment=${CONF_ENV}=//p" "${DEFINITION}" 2>/dev/null | head -1 || true)"
    DEFINITION_PUB="$(sed -n "s/^Environment=${PUBCFG_ENV}=//p" "${DEFINITION}" 2>/dev/null | head -1 || true)"
    # systemd 的值可能带引号（路径含空白时）；去掉一对包裹引号。
    DEFINITION_CONF="${DEFINITION_CONF%\"}"
    DEFINITION_CONF="${DEFINITION_CONF#\"}"
    DEFINITION_PUB="${DEFINITION_PUB%\"}"
    DEFINITION_PUB="${DEFINITION_PUB#\"}"
  fi
fi

# 跑 unlink 用哪个 gwlinkd：显式指定 > 服务已装的那个 > 本地构建（debug）。
GWLINKD_BIN="${WIST_GWLINKD_DEV_BIN:-${DEFINITION_BIN:-${LOCAL_GWLINKD_BIN}}}"
CONFIG="${WIST_GWLINKD_DEV_CONFIG:-${DEFINITION_CONF:-${LEGACY_CONFIG}}}"
PUB="${WIST_GWLINKD_DEV_PUB_CONFIG:-${DEFINITION_PUB:-${PUB_DEFAULT}}}"

# gwlinkd unlink 的开关，原样透传。
GWLINKD_ARGS=()
if [[ "${DRY_RUN}" == "1" ]]; then
  GWLINKD_ARGS+=("--dry-run")
fi
if [[ "${FORGET_CENTER}" == "1" ]]; then
  GWLINKD_ARGS+=("--forget-center")
fi

[[ -f "${CONFIG}" ]] || {
  echo "没有 gwlinkd 配置（${CONFIG}），本机就谈不上与 Center 有连接 —— 无需清理。"
  echo "（配置在哪由服务定义决定；没装过服务时是 ${LEGACY_CONFIG}。）"
  exit 0
}

[[ -x "${GWLINKD_BIN}" ]] || die "缺少 gwlinkd 二进制：${GWLINKD_BIN}
先构建：./dev/install-gwlinkd-dev.sh（或 cargo build --release --manifest-path ${ROOT_DIR}/wist-gwlinkd/Cargo.toml）"

echo "断开本机网关与 Center 的连接（交由 gwlinkd 处理）"
note "gwlinkd   ${GWLINKD_BIN}"
note "配置      ${CONFIG}"
note "现场态    ${PUB}"
if [[ -f "${DEFINITION}" ]]; then
  note "服务定义  ${DEFINITION}（停/起走服务管理器）"
else
  note "服务定义  无（老的 nohup 形态：只停，不自动起回）"
fi
echo

# ── 停 gwlinkd ─────────────────────────────────────────────────────────────
# 运行中的 gwlinkd 会拒绝 unlink（它会不停写回凭据）—— 先停。干跑不停进程（要看的就是「现状下会做什么」）。
if [[ "${DRY_RUN}" == "1" ]]; then
  note "DRY_RUN：不停 gwlinkd；交给 gwlinkd unlink 判断（若在跑会直接拒绝并提示）"
  echo
else
  echo "== 停 gwlinkd =="
  if [[ -f "${DEFINITION}" ]]; then
    if [[ "${PLATFORM}" == "launchd" ]]; then
      run ${SUDO} launchctl bootout "system/${LAUNCHD_LABEL}" || warn "launchctl bootout 未成功（可能本就没在跑）"
    elif [[ "${PLATFORM}" == "systemd" ]]; then
      run ${SUDO} systemctl stop "${SERVICE_NAME}" || warn "systemctl stop 未成功（可能本就没在跑）"
    fi
  fi
  # 兜底：老的 nohup 形态 / 手工 `wist-gwlinkd run` —— 不归服务管理器管，但一样占着 state 目录。
  stray_pid="$(pgrep -f 'wist-gwlinkd run' 2>/dev/null | head -1 || true)"
  if [[ -n "${stray_pid}" ]]; then
    note "还有非服务托管的 gwlinkd 在跑（pid=${stray_pid}）：停掉"
    run kill "${stray_pid}" || warn "kill ${stray_pid} 未成功（若仍在跑，unlink 会拒绝）"
    sleep 1
  fi
  echo
fi

echo "== gwlinkd unlink =="
# 空数组展开在 `set -u` + macOS 自带 bash 3.2 下会报 unbound variable —— 用 `+` 形式护一下。
WIST_GWLINKD_CONFIG="${CONFIG}" WIST_GWLINKD_PUB_CONFIG="${PUB}" \
  "${GWLINKD_BIN}" unlink ${GWLINKD_ARGS[@]+"${GWLINKD_ARGS[@]}"}
echo

# ── 起回 gwlinkd ───────────────────────────────────────────────────────────
# 默认把服务**起回**（回到「等待页面接入请求」的常驻态）—— 组件不断档，不用手动再起。
# 要它就那样停着就加 --no-restart。
if [[ "${DRY_RUN}" == "1" ]]; then
  note "（--dry-run：未动进程）"
elif [[ "${NO_RESTART}" == "1" ]]; then
  note "（--no-restart：gwlinkd 保持停止；要起回：./dev/install-gwlinkd-dev.sh 或手工启动服务）"
elif [[ -f "${DEFINITION}" ]]; then
  echo "== 起回 gwlinkd 服务 =="
  if [[ "${PLATFORM}" == "launchd" ]]; then
    run ${SUDO} launchctl bootstrap system "${DEFINITION}" || warn "launchctl bootstrap 未成功"
    run ${SUDO} launchctl enable "system/${LAUNCHD_LABEL}" || true
  elif [[ "${PLATFORM}" == "systemd" ]]; then
    run ${SUDO} systemctl start "${SERVICE_NAME}" || warn "systemctl start 未成功"
  fi
  echo
else
  note "没有服务定义：gwlinkd 未托管，无从起回（装：./dev/install-gwlinkd-dev.sh）"
fi

cat <<'EOF'
── 重新接入 ─────────────────────────────────────────────
  到网关「链接上级」页粘一条**新的**接入链接（含中心地址 + 接入券 + CA）——
  gwlinkd 在跑（无券）时会自动拉取并完成 link-upstream → register。

── 注意 ────────────────────────────────────────
  * Center 侧**未注销**：那边这台网关仍是已初始化状态，link-upstream 不再置备。
    同一个 gateway_id **无法**再接入（中心无「重置实例」路径，且这是**有意**的安全边界——
    不把「初始化后可再置备」这个口子开出来）。要再接入就在 Center **新建一个实例**，
    用它的**新 gateway_id**（gwlinkd 会按新接入链接自动切过去）。
  * 网关「链接上级」页：unlink 会把「已断开接入」主动告知网关（环回 linkd-status），
    页面（接入状态卡）随即显示「未接入」；服务起回后又刷新为「等待接入」。
    若当时网关没起、或没配 `gateway_self_endpoint`（告知失败），页面要等心跳失联（~90s）才翻。
EOF

if [[ "${FORGET_CENTER}" == "1" ]]; then
  cat <<'EOF'
  * 已 --forget-center：中心信任锚已清，gwlinkd 下次启动会 WARN「未找到信任锚，回落公共根」——
    重接时页面会把新的 CA 写回，即恢复正常。
EOF
else
  cat <<'EOF'
  * 中心信任锚（trust_bundle 的 PEM，中心 CA）已**保留** —— 它是中心的公开证书，不是连接。
    要连它一起清就加 --forget-center（之后 gwlinkd 会 WARN 回落公共根，重接时写回新 CA 即恢复）。
EOF
fi
