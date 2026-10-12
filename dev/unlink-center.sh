#!/usr/bin/env bash
# 断开本机网关与上级控制中心（Center）的连接（开发态）。
#
# **清理逻辑归 `wist-gwlinkd`**（与 link/`onboard` 同一个 owner，见 `wist-gwlinkd/src/unlink.rs`）：
# 「与 Center 的连接」= gwlinkd 手里的注册态（客户端证书 / 链接配置 / 注册券 / 身份 / 实例），
# 加上**现场态配置**里的一次性接入券 `link_token`。unlink 由 gwlinkd 自己删，本脚本只负责开发态的
# 接线 —— **停掉 gwlinkd，再调 `wist-gwlinkd unlink`**，不做任何文件手术。
#
#   * 不碰中心信任锚（trust_bundle 的 PEM）—— 它是中心的公开证书，不是连接；`--forget-center` 才删。
#   * 需先停 gwlinkd（运行中的常驻会不停写回凭据）；本脚本默认替你**停 → unlink → 再起回**
#     （`svc.sh stop gwlinkd` → `wist-gwlinkd unlink` → `svc.sh start gwlinkd`），
#     所以 unlink 完组件仍在（回到「等待页面接入请求」），不会只剩个停着的常驻。
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
# 可覆盖 env（与 svc.sh / setup-domain.sh 同口径）：
#   WIST_GWLINKD_HOME  gwlinkd 配置 + 状态目录（默认 <本目录>/configs/gwlinkd）
#   DRY_RUN=1          等价 --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GWLINKD_HOME="${WIST_GWLINKD_HOME:-${SCRIPT_DIR}/configs/gwlinkd}"
CONFIG="${GWLINKD_HOME}/gwlinkd.toml"
# 现场态配置（中心地址 / 网关标识 / 中心信任锚 / 临时接入券）与主配置**分文件**，
# 并在栈根 `identity/gwlinkd/`（dev 与发布态共用同一份）—— unlink 去券要看的是它。
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PUB="${WIST_GWLINKD_PUB_CONFIG:-${STACK_ROOT}/identity/gwlinkd/gwlinkd-pub.toml}"
GWLINKD_BIN="${SCRIPT_DIR}/../../wist-gwlinkd/target/debug/wist-gwlinkd"

usage() {
  cat <<'EOF'
用法：./dev/unlink-center.sh [--dry-run] [--forget-center] [--no-restart]
      ./dev/unlink-center.sh                   # 停 gwlinkd → unlink → 再起回 gwlinkd
      ./dev/unlink-center.sh --dry-run         # 只看将做什么（不落盘；也不停/不起进程）
      ./dev/unlink-center.sh --forget-center   # 连中心 CA（trust_bundle）也一并清掉
      ./dev/unlink-center.sh --no-restart      # unlink 后**不**起回 gwlinkd（保持停止）
可覆盖 env：WIST_GWLINKD_HOME（默认 <本目录>/configs/gwlinkd）  DRY_RUN=1（等价 --dry-run）
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

note() {
  echo "  $*"
}

DRY_RUN="${DRY_RUN:-0}"
FORGET_CENTER=0
NO_RESTART=0
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
  echo "（缺配置时 svc.sh start 会生成一份模板。）"
  exit 0
}

[[ -x "${GWLINKD_BIN}" ]] || die "缺少 gwlinkd 二进制：${GWLINKD_BIN}
先构建：./dev/svc.sh start gwlinkd（或 cargo build --manifest-path ../../wist-gwlinkd/Cargo.toml）"

echo "断开本机网关与 Center 的连接（开发态，交由 gwlinkd 处理）"
note "gwlinkd home : ${GWLINKD_HOME}"
note "配置         : ${CONFIG}"
note "现场态配置   : ${PUB}"
echo

# 运行中的 gwlinkd 会拒绝 unlink（它会不停写回凭据）—— 先停。干跑不停进程（要看的就是「现状下会做什么」）。
if [[ "${DRY_RUN}" == "1" ]]; then
  note "DRY_RUN：不停 gwlinkd；交给 gwlinkd unlink 判断（若在跑会直接拒绝并提示）"
else
  if [[ -f "${SCRIPT_DIR}/svc.sh" ]]; then
    echo "== 停 gwlinkd =="
    bash "${SCRIPT_DIR}/svc.sh" stop gwlinkd || note "（svc.sh stop gwlinkd 未成功；若仍在跑，unlink 会拒绝）"
    echo
  else
    note "找不到 ${SCRIPT_DIR}/svc.sh，跳过停进程（请自行确认没有 gwlinkd 在跑）"
    echo
  fi
fi

echo "== gwlinkd unlink =="
# 空数组展开在 `set -u` + macOS 自带 bash 3.2 下会报 unbound variable —— 用 `+` 形式护一下。
WIST_GWLINKD_CONFIG="${CONFIG}" WIST_GWLINKD_PUB_CONFIG="${PUB}" \
  "${GWLINKD_BIN}" unlink ${GWLINKD_ARGS[@]+"${GWLINKD_ARGS[@]}"}
echo

# unlink 完**默认把 gwlinkd 起回**（回到「等待页面接入请求」的常驻态）—— 组件不断档，
# 不用手动再起。要它就那样停着就加 --no-restart。
RESTART_NOTE="（--dry-run：未动进程）"
if [[ "${DRY_RUN}" == "1" ]]; then
  :
elif [[ "${NO_RESTART}" == "1" ]]; then
  RESTART_NOTE="（--no-restart：gwlinkd 保持停止；要再接入先 ./dev/svc.sh start gwlinkd）"
elif [[ -f "${SCRIPT_DIR}/svc.sh" ]]; then
  echo "== 重启 gwlinkd（回到等待接入）=="
  if bash "${SCRIPT_DIR}/svc.sh" start gwlinkd --no-build; then
    RESTART_NOTE="（已重新起回 gwlinkd，无券 → 等页面接入请求）"
  else
    RESTART_NOTE="（重启 gwlinkd 未成功，请手动 ./dev/svc.sh start gwlinkd）"
  fi
  echo
else
  RESTART_NOTE="（找不到 svc.sh，未重启；请自行确认 gwlinkd 是否在跑）"
fi
note "${RESTART_NOTE}"
echo

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
    页面（接入状态卡）随即显示「未接入」；起回 gwlinkd 后又刷新为「等待接入」。
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
