#!/usr/bin/env bash
# 在**服务那份配置**上跑 wist-gwlinkd（开发态）—— 省掉那三串超长路径。
#
# 手动跑一次 gwlinkd 子命令，本来要写全：
#   bin     /usr/local/bin/wist-gwlinkd
#   config  <栈根>/configs/gwlinkd/gwlinkd.toml          # 例：~/devspace/.../wist-gateway-stack/configs/gwlinkd/gwlinkd.toml
#   pub     <栈根>/identity/gwlinkd/gwlinkd-pub.toml     # 同长
#   $ <bin> diagnose --conf <config> --pub <pub>
#
# 本脚本把这三样**从已装的服务定义里读出来**（与 `install-gwlinkd-dev.sh` / `unlink-center.sh`
# 同一口径：读不到才退回本地构建 + 老 nohup 形态的配置），原样传给 gwlinkd。于是：
#
#   ./dev/gwlinkd.sh diagnose             # = <bin> diagnose --conf <config> --pub <pub>
#   ./dev/gwlinkd.sh version
#   ./dev/gwlinkd.sh service status --system
#   ./dev/gwlinkd.sh --paths              # 只打印解析出来的三样路径（想知道“到底读哪份”时用）
#
# 注：`wist-gwlinkd` **自己也认得**这份配置 —— `--conf` 缺省时 `diagnose` / `service status` 会读已装服务定义
# （见它自己的 README）。所以装了新版二进制后，直接 `wist-gwlinkd diagnose` 就够。本脚本多出来的是：
# `--paths` 看落点、`--bin` 指定**本地构建**（不经系统服务），以及在旧二进制上也能用。
#
# 它**只是穿透**：不改任何东西、不管进程生命周期（停/起服务走 `install-gwlinkd-dev.sh` 打印的
# 服务命令；断开接入走 `unlink-center.sh`）。要 root 的子命令自己 `sudo ./dev/gwlinkd.sh …`
# （或直接 `sudo /usr/local/bin/wist-gwlinkd …` —— sudo 下 HOME 会变，别指望本脚本）。
#
# 用法：
#   ./dev/gwlinkd.sh <子命令> [参数…]
#   ./dev/gwlinkd.sh --bin <gwlinkd 路径> <子命令> [参数…]   # 换二进制（默认：服务已装的 > 本地构建）
#   ./dev/gwlinkd.sh --paths                                # 只看三样路径，不执行
#
# 可覆盖 env（与 install-gwlinkd-dev.sh / unlink-center.sh 同口径）：
#   WIST_GWLINKD_DEV_BIN / WIST_GWLINKD_DEV_CONFIG / WIST_GWLINKD_DEV_PUB_CONFIG
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# $WIST（crate 所在仓组根）—— 与 svc.sh 同一套解析（脚本可能落在 wist/ 组内，也可能与组件同级）。
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
if [[ -d "${ROOT_DIR}/wist/wist-gateway" ]]; then
  ROOT_DIR="${ROOT_DIR}/wist"
elif [[ -d "${ROOT_DIR}/../wist/wist-gateway" ]]; then
  ROOT_DIR="$(cd -- "${ROOT_DIR}/../wist" && pwd)"
fi
LOCAL_GWLINKD_BIN="${ROOT_DIR}/wist-gwlinkd/target/debug/wist-gwlinkd"

# 服务 / 发布态的固定落点（与 wist-gwlinkd 的 src/service/* 常量一致）。
SERVICE_NAME="wist-gwlinkd"
LAUNCHD_LABEL="com.dayu-sec.wist-gwlinkd"
CONF_ENV="WIST_GWLINKD_CONFIG"
PUBCFG_ENV="WIST_GWLINKD_PUB_CONFIG"
# 老的 nohup 形态（退役）的配置 —— 只在「没有服务定义」时作兜底。
LEGACY_CONFIG="${STACK_ROOT}/dev/configs/gwlinkd/gwlinkd.toml"
PUB_DEFAULT="${STACK_ROOT}/identity/gwlinkd/gwlinkd-pub.toml"

die() { echo "错误：$*" >&2; exit 1; }
note() { echo "  $*"; }

usage() {
  # 打印文件头的注释块（第 3 行起，到首个非注释行为止）。
  awk 'NR>=3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

case "$(uname -s)" in
  Darwin) PLATFORM="launchd"; DEFINITION="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist" ;;
  Linux) PLATFORM="systemd"; DEFINITION="/etc/systemd/system/${SERVICE_NAME}.service" ;;
  *) PLATFORM="unsupported"; DEFINITION="" ;;
esac

BIN_OVERRIDE=""
SHOW_PATHS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --paths) SHOW_PATHS=1; shift ;;
    --bin)
      BIN_OVERRIDE="${2:-}"
      [[ -n "${BIN_OVERRIDE}" ]] || die "--bin 需要一个值"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) break ;;
  esac
done
CMDLINE=("$@")

# ── 从服务定义里读 bin / config / pub（读不到才退回老 nohup 形态那一套）──
# 为什么要读而不是猜：服务跑的就是这几条路径；猜错就会「诊断的是另一份配置」，
# 症状是 diagnose 一切正常但服务在报错（或反之）—— 最难查的一类。
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
    DEFINITION_CONF="${DEFINITION_CONF%\"}"
    DEFINITION_CONF="${DEFINITION_CONF#\"}"
    DEFINITION_PUB="${DEFINITION_PUB%\"}"
    DEFINITION_PUB="${DEFINITION_PUB#\"}"
  fi
fi

GWLINKD_BIN="${BIN_OVERRIDE:-${WIST_GWLINKD_DEV_BIN:-${DEFINITION_BIN:-${LOCAL_GWLINKD_BIN}}}}"
CONFIG="${WIST_GWLINKD_DEV_CONFIG:-${DEFINITION_CONF:-${LEGACY_CONFIG}}}"
PUB="${WIST_GWLINKD_DEV_PUB_CONFIG:-${DEFINITION_PUB:-${PUB_DEFAULT}}}"

if [[ "${SHOW_PATHS}" == "1" ]]; then
  if [[ -f "${DEFINITION}" ]]; then
    note "服务定义 ${DEFINITION}"
  else
    note "服务定义 无（退回：本地构建 + 老 nohup 形态的配置）"
  fi
  note "bin     ${GWLINKD_BIN}$([[ -x "${GWLINKD_BIN}" ]] || printf '（不存在）')"
  note "config  ${CONFIG}$([[ -f "${CONFIG}" ]] || printf '（不存在）')"
  note "pub     ${PUB}$([[ -f "${PUB}" ]] || printf '（不存在）')"
  exit 0
fi

if [[ ${#CMDLINE[@]} -eq 0 ]]; then
  # 默认子命令是 `run`（起常驻）—— 穿透脚本不替你选，免得一条手滑就把常驻又起一个。
  echo "用法：./dev/gwlinkd.sh <子命令> [参数…]   （如 diagnose / version / service status --system）" >&2
  echo "      ./dev/gwlinkd.sh --paths              # 看解析出的 bin / config / pub" >&2
  exit 2
fi

[[ -x "${GWLINKD_BIN}" ]] || die "缺少 gwlinkd 二进制：${GWLINKD_BIN}
先构建：./dev/install-gwlinkd-dev.sh（或 cargo build --manifest-path ${ROOT_DIR}/wist-gwlinkd/Cargo.toml）"
[[ -f "${CONFIG}" ]] || die "找不到主配置：${CONFIG}（用 ./dev/gwlinkd.sh --paths 看它读的是哪份）"

# 全局选项放在子命令**之后**也认（`parse_global_paths` 允许前后都行），所以直接追加。
exec "${GWLINKD_BIN}" "${CMDLINE[@]}" --conf "${CONFIG}" --pub "${PUB}"
