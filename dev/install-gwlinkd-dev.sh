#!/usr/bin/env bash
# 把**本机编译的** wist-gwlinkd 发布到**已装的系统服务**（开发机自用）。
#
# 场景：这台机器的 gwlinkd 已作为系统服务常驻（发布态安装脚本装的）：
#   bin=<DEST_BIN>（默认 /usr/local/bin/wist-gwlinkd）  config=<栈根>/configs/gwlinkd/gwlinkd.toml
#   pub=<栈根>/identity/gwlinkd/gwlinkd-pub.toml        UserName=<部署用户>
# 你在改 gwlinkd 源码，想让**这个服务跑的就是你刚编出来的那份**（而不是发布制品）。
#
# 与邻居的分工，别混：
#   install.sh（中心签发）  从中心下载制品 → 装 /usr/local/bin → 装成系统服务。生产 / 批量用。
#   本脚本                 把 <crate>/target/{release,debug} 里刚编出来的二进制**拷到服务的位置**，
#                          以**服务现有的发布态配置**重渲染定义 + 重启，供「我想让本机服务跑我刚改的代码」用。
#
# 注：gwlinkd 已**不再由 `dev/svc.sh` 管**（svc.sh 不构建/不起/不停它）—— 发布态与开发态都走系统服务。
#
# 它**只动二进制 + 服务定义**：不写配置、不碰注册态 / 凭据，enrollment 与 state 原样。可回滚。
#
# 用法：
#   ./dev/install-gwlinkd-dev.sh             # 构建 debug → 备份旧二进制 → 换上 → 重写定义并重启 → 验证
#   ./dev/install-gwlinkd-dev.sh --dry-run   # 只打印将执行的命令（含渲染出的服务定义），不落任何字
#   ./dev/install-gwlinkd-dev.sh --release   # 用 target/release 的产物（默认 debug，与 dev 其余脚本同口径）
#   ./dev/install-gwlinkd-dev.sh --rollback  # 换回最近一次备份并重启
#   ./dev/install-gwlinkd-dev.sh --status    # 只看服务现状（不构建、不改任何东西）
#   ./dev/install-gwlinkd-dev.sh --no-build  # 不重新构建，用现有产物
#
# 前置：请以**普通用户**运行（不要整个 sudo）—— 需要 root 的步骤脚本自己提权；
# 若整个脚本以 root 跑，`cargo build` 会让 target/ 变成 root 属主，之后普通用户就构建不动了。
#
# 可覆盖 env：
#   WIST_GWLINKD_DEV_BIN_SRC=<dir>    产物目录（默认 <crate>/target/debug；`--release` 时是 target/release）
#   WIST_GWLINKD_DEV_BIN=<path>      服务**入口**路径（默认 /usr/local/bin/wist-gwlinkd）
#                                    是指向真身的符号链接时按**真身**换（中心布局：/usr/local/lib/wist-gwlinkd/）
#   WIST_GWLINKD_DEV_CONFIG=<path>   主配置（默认取服务现有定义里的，退回 <栈根>/configs/gwlinkd/gwlinkd.toml）
#   WIST_GWLINKD_DEV_PUB_CONFIG=<path> 现场态配置（同上口径）
#   SKIP_BUILD=1                      等价 --no-build
#   WIST_GWLINKD_DEV_DRY_RUN=1        等价 --dry-run
#   WIST_GWLINKD_DEV_READY_WAIT_SECS  重启后就绪等待上限（默认 30s）
#
# 注意：`service install --force` 会按 bin/config **重渲染服务定义**（等价于当前定义）。
# 手工改过 plist/unit 的内容会被覆盖 —— 要保留就改本脚本传的参数，别直接改定义文件。
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
GWLINKD_CRATE="${ROOT_DIR}/wist-gwlinkd"

# 服务 / 发布态的固定落点（与 wist-gwlinkd 的 src/service/* 常量、栈的 sys/setting 一致）。
SERVICE_NAME="wist-gwlinkd"
LAUNCHD_LABEL="com.dayu-sec.wist-gwlinkd"
CONF_ENV="WIST_GWLINKD_CONFIG"
PUBCFG_ENV="WIST_GWLINKD_PUB_CONFIG"
RELEASE_CONF="${STACK_ROOT}/configs/gwlinkd/gwlinkd.toml"
RELEASE_PUB="${STACK_ROOT}/identity/gwlinkd/gwlinkd-pub.toml"
# 退役的 nohup 形态留下的 pidfile（旧 svc.sh 写的）：只用来揭发“还在跑的老实例”，不再由它接管。
GWLINKD_LEGACY_PIDFILE="${STACK_ROOT}/dev/configs/gwlinkd/gwlinkd.pid"

PROFILE="debug"
MODE="install"
DRY_RUN="${WIST_GWLINKD_DEV_DRY_RUN:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
READY_WAIT_SECS="${WIST_GWLINKD_DEV_READY_WAIT_SECS:-30}"

# ---------------------------------------------------------------- 输出约定
# `== xxx ==` 是脚本自己推进的步骤；`  ` 缩进的是细节 / 外部工具输出 —— 一眼看出停在哪一步。
die() { echo "错误：$*" >&2; exit 1; }
note() { echo "  $*"; }
warn() { echo "  [warn] $*" >&2; }
pass() { echo "  [ok] $*"; }
bad() { echo "  [FAIL] $*" >&2; }

usage() {
  # 打印文件头的**注释块**（第 3 行起，到首个非注释行为止）：加/删注释行都不用改行号。
  awk 'NR>=3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# 干跑：只打印将执行的命令。注意 `${SUDO}` 是**空串**（普通用户）或 `sudo`（系统级），
# 展开后为空是**设了值**的变量，`set -u` 下不报错。
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '    [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

# 路径显示：$HOME 下折叠成 ~（日志里短一点、也好认）。
short() {
  case "$1" in
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# sha256：macOS 是 shasum，Linux 是 sha256sum —— 都缺就返回空（校验降级为「不打印摘要」）。
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}
sha12() { printf '%s' "$(sha256_of "$1" 2>/dev/null || true)" | cut -c1-12; }

pid_alive() { [[ -n "$1" ]] && ps -p "$1" >/dev/null 2>&1; }

case "$(uname -s)" in
  Darwin)
    PLATFORM="launchd"
    DEFINITION="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
    LOG_HINT="sudo tail -f /var/log/wist-gwlinkd/gwlinkd.err"
    ;;
  Linux)
    PLATFORM="systemd"
    DEFINITION="/etc/systemd/system/${SERVICE_NAME}.service"
    LOG_HINT="journalctl -u ${SERVICE_NAME} -f"
    ;;
  *) die "不支持平台：$(uname -s)（只支持 macOS launchd / Linux systemd）" ;;
esac

# ---------------------------------------------------------------- 参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-build) SKIP_BUILD=1 ;;
    --release) PROFILE="release" ;;
    --status) MODE="status" ;;
    --rollback) MODE="rollback" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "未知参数：$1"
      ;;
  esac
  shift
done

BIN_SRC_DIR="${WIST_GWLINKD_DEV_BIN_SRC:-${GWLINKD_CRATE}/target/${PROFILE}}"
SRC_BIN="${BIN_SRC_DIR}/wist-gwlinkd"

# 中心的安装布局：`/usr/local/bin/wist-gwlinkd` 只是**符号链接**，真身在
# `/usr/local/lib/wist-gwlinkd/wist-gwlinkd`（目录与文件都归运行用户 —— gwlinkd 的自更新要在
# 进程内就地把真身换掉）。服务定义里的 `--bin` 用入口路径。
SERVICE_BIN="${WIST_GWLINKD_DEV_BIN:-/usr/local/bin/wist-gwlinkd}"
GWLINKD_REAL_DIR='/usr/local/lib/wist-gwlinkd'

# 顺着符号链接找到**真身**：要换的是真身，不是入口。直接用 `install` 写入口路径会把符号链接
# 换成 root 属主的普通文件，`/usr/local/bin` 又归 root —— 之后自更新 preflight 写探测直接 EACCES。
resolve_link() {
  local p="$1" t
  while [[ -L "$p" ]]; do
    t="$(readlink "$p")" || break
    case "$t" in
      /*) p="$t" ;;
      *) p="$(cd -- "$(dirname -- "$p")" && pwd -P)/$t" ;;
    esac
  done
  # 归一化（去掉链接里的 `..` / 相对段）；目录不存在时原样返回。
  if [[ -d "$(dirname -- "$p")" ]]; then
    printf '%s\n' "$(cd -- "$(dirname -- "$p")" && pwd -P)/$(basename -- "$p")"
  else
    printf '%s\n' "$p"
  fi
}
DEST_BIN="$(resolve_link "${SERVICE_BIN}")"
DEST_DIR="$(dirname -- "${DEST_BIN}")"

# 系统级服务要 root：脚本自己提权（而不是要求外层 sudo —— 那会把 cargo build 也变成 root）。
# 落点目录若已归运行用户（中心布局），就**不提权**：写出来的文件才仍是运行用户的。
if [[ -w "${DEST_DIR}" ]]; then SUDO=""; else SUDO="sudo"; fi
# 服务的运行身份：以**部署用户**跑，别用 root（gwlinkd 会回写配置 / 落身份 / 驱动 gops 升级，
# 那些都该是部署用户的属主）。这与中心安装脚本的 `--run-as <部署用户>` 同口径。
RUN_AS_ARGS=(--run-as "$(id -un)")

# ---------------------------------------------------------------- 解析「服务现有定义」里的配置路径
# 用户要的是「沿用**现有的发布态**」——不靠猜：直接从已装的 plist / unit 里读它当年写进去的
# `WIST_GWLINKD_CONFIG` / `WIST_GWLINKD_PUB_CONFIG`（读不到才退回本栈的发布态缺省路径）。
DEFINITION_CONF=""
DEFINITION_PUB=""
read_definition_paths() {
  [[ -f "${DEFINITION}" ]] || return 0
  if [[ "${PLATFORM}" == "launchd" ]]; then
    command -v plutil >/dev/null 2>&1 || return 0
    DEFINITION_CONF="$(plutil -extract "EnvironmentVariables.${CONF_ENV}" raw -o - "${DEFINITION}" 2>/dev/null || true)"
    DEFINITION_PUB="$(plutil -extract "EnvironmentVariables.${PUBCFG_ENV}" raw -o - "${DEFINITION}" 2>/dev/null || true)"
  else
    DEFINITION_CONF="$(sed -n "s/^Environment=${CONF_ENV}=//p" "${DEFINITION}" 2>/dev/null | head -1 || true)"
    DEFINITION_PUB="$(sed -n "s/^Environment=${PUBCFG_ENV}=//p" "${DEFINITION}" 2>/dev/null | head -1 || true)"
    # systemd 的值可能带引号（路径含空白时）；去掉一对包裹引号。
    DEFINITION_CONF="${DEFINITION_CONF%\"}"
    DEFINITION_CONF="${DEFINITION_CONF#\"}"
    DEFINITION_PUB="${DEFINITION_PUB%\"}"
    DEFINITION_PUB="${DEFINITION_PUB#\"}"
  fi
}
read_definition_paths

CONF="${WIST_GWLINKD_DEV_CONFIG:-${DEFINITION_CONF:-${RELEASE_CONF}}}"
PUB="${WIST_GWLINKD_DEV_PUB_CONFIG:-${DEFINITION_PUB:-${RELEASE_PUB}}}"

# ---------------------------------------------------------------- 服务状态（只读）
service_status_raw() {
  "${SERVICE_BIN}" service status --system "${RUN_AS_ARGS[@]}" \
    --bin "${SERVICE_BIN}" --config "${CONF}" --pub-config "${PUB}"
}

show_status() {
  echo "== gwlinkd 服务现状 =="
  note "服务定义 ${DEFINITION}"
  note "入口     $(short "${SERVICE_BIN}")"
  [[ "${DEST_BIN}" == "${SERVICE_BIN}" ]] || note "真身     $(short "${DEST_BIN}")"
  note "配置     $(short "${CONF}")"
  note "现场态   $(short "${PUB}")"
  echo
  if [[ ! -x "${SERVICE_BIN}" ]]; then
    warn "服务二进制不存在：${SERVICE_BIN}（发布态还没装过？）"
    return 0
  fi
  service_status_raw 2>&1 | sed 's/^/  /' || warn "service status 未成功"
}

# ---------------------------------------------------------------- 步骤

build() {
  echo "== 构建 ${PROFILE} 产物 =="
  if [[ "${SKIP_BUILD}" == "1" ]]; then
    note "SKIP_BUILD=1 / --no-build：跳过 cargo build"
  else
    require_cmd cargo
    if [[ "${PROFILE}" == "release" ]]; then
      run cargo build --release --manifest-path "${GWLINKD_CRATE}/Cargo.toml"
    else
      run cargo build --manifest-path "${GWLINKD_CRATE}/Cargo.toml"
    fi
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    note "产物 ${SRC_BIN}$([[ -x "${SRC_BIN}" ]] || printf '（尚未构建）')"
    return 0
  fi
  [[ -x "${SRC_BIN}" ]] || die "缺少可执行文件：${SRC_BIN}
  （先构建；或用 WIST_GWLINKD_DEV_BIN_SRC 指定产物目录）"
  note "$(basename "${SRC_BIN}")  $(sha12 "${SRC_BIN}")  $("${SRC_BIN}" version 2>/dev/null | head -1 || echo '?')"
}

# gwlinkd 与**任何**其他实例（含老的 nohup 形态）都抢同一个 state 目录的 flock：
# 老的 svc.sh 用 nohup 起的那个不归服务管理器管，它在跑，服务就永远起不来。
# svc.sh 如今已不管 gwlinkd（不再写这个 pidfile）—— 这里只兜底清掉**以前留下的**那个残留进程。
release_legacy_console_instance() {
  echo "== 清理老的 nohup 形态残留（若有）=="
  local console_pid=""
  if [[ -f "${GWLINKD_LEGACY_PIDFILE}" ]]; then
    console_pid="$(cat "${GWLINKD_LEGACY_PIDFILE}" 2>/dev/null || true)"
  fi
  if ! pid_alive "${console_pid}"; then
    note "没有残留（gwlinkd 现在只归系统服务，独占这个 state 目录）"
    run rm -f "${GWLINKD_LEGACY_PIDFILE}"
    return 0
  fi
  note "老的 nohup gwlinkd 还在跑（pid=${console_pid}）：停掉（它不归服务管理器管，却占着单实例锁）"
  run kill "${console_pid}" || warn "kill ${console_pid} 未成功，服务可能起不来（见后面的验证）"
  run rm -f "${GWLINKD_LEGACY_PIDFILE}"
}

# gwlinkd 的自更新是“取制品 → 同目录写临时文件 → rename 覆盖真身”，所以**目录**必须对运行用户
# 可写（只给文件写权限不够）。中心布局把真身放 /usr/local/lib/wist-gwlinkd（目录与文件都归运行用户），
# 入口 /usr/local/bin/wist-gwlinkd 只做符号链接。换完只做体检：不达标就当场说清后果和修法，
# 别等中心派升级计划时才在 gwlinkd 日志里报 preflight EACCES。
self_update_layout_check() {
  if [[ "${DRY_RUN}" == "1" ]]; then return 0; fi
  if [[ -w "${DEST_DIR}" ]]; then
    pass "自更新布局就绪：$(short "${DEST_DIR}") 对 $(id -un) 可写"
    return 0
  fi
  warn "自更新会失败：目录 $(short "${DEST_DIR}") 对 $(id -un) 不可写（原子 rename 需要目录可写，只给文件权限不够）。"
  warn "期望布局：真身 ${GWLINKD_REAL_DIR}/wist-gwlinkd（目录与文件归运行用户），$(short "${SERVICE_BIN}") 只做符号链接。"
  warn "修复：在中心网关页重跑「只装 gwlinkd」命令；或把 WIST_GWLINKD_DEV_BIN 指到运行用户可写的目录。"
}

swap_binary() {
  echo "== 备份并替换服务二进制（真身） =="
  local ts bak created_dir=0
  ts="$(date '+%Y%m%d-%H%M%S')"
  bak="${DEST_BIN}.bak-${ts}"

  if [[ ! -d "${DEST_DIR}" ]]; then
    created_dir=1
    run ${SUDO} install -d -m 0755 "${DEST_DIR}"
  fi

  if [[ -f "${DEST_BIN}" ]]; then
    note "旧 $(basename "${DEST_BIN}")  $(sha12 "${DEST_BIN}")  → 备份为 $(short "${bak}")"
    run ${SUDO} cp -p "${DEST_BIN}" "${bak}"
  else
    note "$(short "${DEST_BIN}") 不存在：这是一次**首次安装**（只装服务，不写配置、不碰注册）"
  fi

  # 先落 .new 再 mv：mv 是原子改名（换 inode），而原地覆盖旧 inode 踩过坑 ——
  # 运行中的进程 / 随后 exec 会抓到旧内容。
  run ${SUDO} install -m 0755 "${SRC_BIN}" "${DEST_BIN}.new"
  run ${SUDO} mv -f "${DEST_BIN}.new" "${DEST_BIN}"
  # 走了 sudo 的话文件是 root 属主；自更新期望目录与文件**都归运行用户**，这里把文件交回去。
  if [[ -n "${SUDO}" ]]; then
    run ${SUDO} chown "$(id -un)" "${DEST_BIN}"
    # 只在中心那个专用目录上连目录一起交回（不能去改共用的 /usr/local/bin 属主）。
    if [[ "${created_dir}" == "1" && "${DEST_DIR}" == "${GWLINKD_REAL_DIR}" ]]; then
      run ${SUDO} chown "$(id -un)" "${DEST_DIR}"
    fi
  fi
  self_update_layout_check

  if [[ "${DRY_RUN}" == "1" ]]; then
    note "将换上 $(basename "${DEST_BIN}")  $(sha12 "${SRC_BIN}")"
    return 0
  fi
  # 后置校验：换完的目标必须与产物逐字节一致（拷失败 / 写到别处都在这里被拦住）。
  local src_hash dst_hash
  src_hash="$(sha12 "${SRC_BIN}")"
  dst_hash="$(sha12 "${DEST_BIN}")"
  if [[ -n "${src_hash}" && "${dst_hash}" == "${src_hash}" ]]; then
    note "新 $(basename "${DEST_BIN}")  ${dst_hash}"
  else
    bad "换上后的摘要不符：产物 ${src_hash:-?}，目标 ${dst_hash:-?}"
    note "回滚：./dev/install-gwlinkd-dev.sh --rollback"
    return 1
  fi
}

# 重写服务定义并重启。`service install --force` 内部会 bootout+bootstrap（launchd）/
# daemon-reload+enable+restart（systemd）—— 重启这一下就带上刚换上的二进制，不必另停。
install_service() {
  echo "== 重写服务定义并重启（service install --force）=="
  if [[ "${DRY_RUN}" == "1" && -x "${SRC_BIN}" ]]; then
    note "将写入的服务定义（service print 渲染）："
    "${SRC_BIN}" service print --system "${RUN_AS_ARGS[@]}" \
      --bin "${SERVICE_BIN}" --config "${CONF}" --pub-config "${PUB}" 2>&1 | sed 's/^/    /' || true
  fi
  run ${SUDO} "${SERVICE_BIN}" service install --force --system "${RUN_AS_ARGS[@]}" \
    --bin "${SERVICE_BIN}" --config "${CONF}" --pub-config "${PUB}"
}

verify() {
  echo "== 验证 =="
  if [[ "${DRY_RUN}" == "1" ]]; then
    note "dry-run：跳过验证"
    return 0
  fi

  # launchd / systemd 异步拉起进程；刚重启完立刻断言必假失败 —— 轮询到 running 或超时。
  # （前任实例还没放掉 flock 时首启会失败，由 Restart / KeepAlive 重试，正好在这里被等到。）
  local waited=0 out=""
  while [[ "${waited}" -lt "${READY_WAIT_SECS}" ]]; do
    out="$(service_status_raw 2>&1 || true)"
    if printf '%s\n' "${out}" | grep -q '^running=yes'; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  printf '%s\n' "${out}" | sed 's/^/  /'
  if printf '%s\n' "${out}" | grep -q '^running=yes'; then
    pass "服务在跑，跑的就是 $(short "${DEST_BIN}")（$(sha12 "${DEST_BIN}")）"
  else
    bad "等了 ${READY_WAIT_SECS}s 服务仍未就绪"
    # 最坑的一种：launchd 自己的 spawn 失败（如 stdio 目录不可写）⇒ **应用日志是空的**，
    # 答案只在 launchd 的日志里。别让人对空目录发呆。
    if [[ "${PLATFORM}" == "launchd" ]]; then
      note "看 launchd（应用日志可能为空）：log show --last 5m --predicate 'eventMessage CONTAINS \"gwlinkd\"' --style compact"
    fi
    note "看日志：${LOG_HINT}"
    note "回滚：./dev/install-gwlinkd-dev.sh --rollback"
    return 1
  fi
}

rollback() {
  echo "== 回滚到最近一次备份 =="
  local newest
  newest="$(ls -1 "${DEST_BIN}.bak-"* 2>/dev/null | sort | tail -1 || true)"
  if [[ -z "${newest}" ]]; then
    die "找不到备份（${DEST_BIN}.bak-*）：本脚本没在这台机器上换过，或备份已被清理"
  fi
  note "备份：$(short "${newest}")  $(sha12 "${newest}")"

  run ${SUDO} install -m 0755 "${newest}" "${DEST_BIN}.new"
  run ${SUDO} mv -f "${DEST_BIN}.new" "${DEST_BIN}"
  if [[ -n "${SUDO}" ]]; then run ${SUDO} chown "$(id -un)" "${DEST_BIN}"; fi
  if [[ "${DRY_RUN}" != "1" ]]; then
    note "已换回 $(sha12 "${DEST_BIN}")"
  fi

  install_service
  verify
}

preflight() {
  echo "== preflight =="
  if [[ "$(id -u)" == "0" && "${DRY_RUN}" != "1" ]]; then
    die "别用 root 跑本脚本：cargo build 会让 target/ 变成 root 属主。
  用普通用户运行；需要 root 的步骤（写 ${DEST_BIN}、装服务）脚本自己 sudo。"
  fi
  note "platform=${PLATFORM} scope=system uid=$(id -u) mode=${MODE} dry_run=${DRY_RUN} profile=${PROFILE}"
  note "产物     ${SRC_BIN}"
  note "服务 bin $(short "${SERVICE_BIN}")$([[ "${DEST_BIN}" == "${SERVICE_BIN}" ]] || printf ' → %s' "$(short "${DEST_BIN}")")"
  if [[ -w "${DEST_DIR}" ]]; then
    note "自更新   $(short "${DEST_DIR}") 对 $(id -un) 可写"
  else
    note "自更新   $(short "${DEST_DIR}") 对 $(id -un) **不可写** → 中心推送的 gwlinkd 升级会失败（重跑中心「只装 gwlinkd」可修）"
  fi
  note "主配置   $(short "${CONF}")$([[ "${DEFINITION_CONF}" == "${CONF}" ]] && printf '（取自服务现有定义）')"
  note "现场态   $(short "${PUB}")$([[ "${DEFINITION_PUB}" == "${PUB}" ]] && printf '（取自服务现有定义）')"
  note "服务定义 ${DEFINITION}"
  note "运行身份 --run-as $(id -un)"
  if [[ ! -f "${DEFINITION}" ]]; then
    note "服务定义不存在：这是一次**首次安装**（换二进制 + 注册服务，不写配置、不碰注册）"
  fi
}

# ---------------------------------------------------------------- main

case "${MODE}" in
  status)
    show_status
    exit 0
    ;;
esac

# 配置是服务运行的前提（缺了 gwlinkd 起不来）—— 与状态模式不同，这里缺就停。
[[ -f "${CONF}" ]] || die "找不到主配置：${CONF}
  （发布态没 localize 过？或用 WIST_GWLINKD_DEV_CONFIG 指定；只换二进制、不改配置）"
[[ -f "${PUB}" ]] || die "找不到现场态配置：${PUB}
  （发布态没 localize 过？或用 WIST_GWLINKD_DEV_PUB_CONFIG 指定）"

preflight
echo

if [[ "${MODE}" == "rollback" ]]; then
  rollback
else
  build
  release_legacy_console_instance
  swap_binary
  install_service
  verify
fi

echo
echo "== 完成 =="
note "服务    ${SERVICE_NAME}（$(short "${SERVICE_BIN}")）"
note "配置    $(short "${CONF}")  +  $(short "${PUB}")"
note "日志    ${LOG_HINT}"
note "状态    ./dev/install-gwlinkd-dev.sh --status"
note "回滚    ./dev/install-gwlinkd-dev.sh --rollback"
if [[ "${MODE}" == "install" && "${DRY_RUN}" != "1" ]]; then
  note "卸载    \`${SUDO} ${SERVICE_BIN} service uninstall --system\`（svc.sh 已不管 gwlinkd）"
fi
