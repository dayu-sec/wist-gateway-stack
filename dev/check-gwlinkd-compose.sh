#!/usr/bin/env bash
# 检查「gwlinkd 的运行身份」能不能跑 `docker compose`。
#
# 为什么需要这条检查：gwlinkd 以 **root**（launchd daemon / systemd 无 `User=`）运行，业务身份生效
# 走 `gops run stop && gops run start` → `docker compose …`。而 `compose` 是 docker 的 **CLI 插件**，
# 只从固定目录发现：`$HOME/.docker/cli-plugins`、`<docker 目录>/cli-plugins`、
# `/usr/local/lib{,exec}/docker/cli-plugins`、`/usr/lib{,exec}/docker/cli-plugins`；而且插件文件
# 必须**可执行**，否则 docker 静默跳过。
#
# 插件在机器上、但运行身份看不见（或文件不可执行）时，`docker compose -f x.yml up` 报的是
# `unknown shorthand flag: 'f' in -f` —— 看着像参数拼错，其实是 docker 先解析参数、后报
# 「不认识 compose 子命令」。（2026-11-09 现场就是这样：租户绑定补偿一直失败，日志只留这一行。）
#
# 用法：
#   dev/check-gwlinkd-compose.sh             # 检查（能真跑就真跑，否则给静态结论）
#   sudo dev/check-gwlinkd-compose.sh        # 以运行身份真跑一次（最权威）
#   sudo dev/check-gwlinkd-compose.sh --fix  # 把插件补进系统级目录并复查
#   dev/check-gwlinkd-compose.sh --quiet     # 只输出一行结论（给安装脚本用）
#
# 退出码：0 可用 / 1 不可用（给出修复） / 3 无法确认（需要 sudo 真跑）
set -euo pipefail

SERVICE_NAME="wist-gwlinkd"
LAUNCHD_LABEL="com.dayu-sec.wist-gwlinkd"
SYSTEM_PLUGIN_DIRS=(
  /usr/local/lib/docker/cli-plugins
  /usr/local/libexec/docker/cli-plugins
  /usr/lib/docker/cli-plugins
  /usr/libexec/docker/cli-plugins
)
# 已知能跑的 compose 安装位置（按优先级）：这些都是**绝对路径**，与 HOME / 发现路径无关。
KNOWN_COMPOSE_BINARIES=(
  /Applications/OrbStack.app/Contents/MacOS/xbin/docker-compose
  /opt/homebrew/bin/docker-compose
  /usr/local/bin/docker-compose
)
FIX_DEST_DIR="/usr/local/lib/docker/cli-plugins"

QUIET=0
FIX=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    --fix) FIX=1 ;;
    -h | --help)
      # 头部注释就是帮助：从第 2 行打到 `set -euo pipefail` 之前（不写死行号，改注释不会错位）。
      awk 'NR > 1 && /^set -euo/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "未知参数：$arg（可用：--fix --quiet）" >&2
      exit 2
      ;;
  esac
done

say() { [[ "${QUIET}" == "1" ]] || echo "$@"; }
# 结论行：--quiet 下也要有一行输出（给安装脚本读）。
concl() {
  if [[ "${QUIET}" == "1" ]]; then echo "$1"; else echo "$1"; fi
}

# ---------------------------------------------------------------- 身份与环境

# 跨平台取用户 HOME（macOS 没有 getent）。
home_of() {
  local user="$1"
  if command -v getent >/dev/null 2>&1; then
    getent passwd "${user}" 2>/dev/null | cut -d: -f6 || true
  else
    dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true
  fi
}

# 只走**一跳**软链并把结果绝对化。
# 不用 realpath：OrbStack 的 `xbin/docker-compose` 本身还指向它的多合一 `docker-tools`，
# 多解一层会把插件指向多合一二进制（能不能跑靠 argv[0]，没必要赌）。一跳保持与用户现有配置一致。
one_hop() {
  local path="$1" target
  if target="$(readlink "${path}" 2>/dev/null)" && [[ -n "${target}" ]]; then
    case "${target}" in
      /*) printf '%s\n' "${target}" ;;
      *) printf '%s\n' "$(cd "$(dirname "${path}")" && cd "$(dirname "${target}")" && pwd)/$(basename "${target}")" ;;
    esac
  else
    printf '%s\n' "${path}"
  fi
}

target_user="root"
definition=""
case "$(uname -s)" in
  Darwin) definition="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist" ;;
  Linux) definition="/etc/systemd/system/${SERVICE_NAME}.service" ;;
esac
if [[ -n "${definition}" && -f "${definition}" ]]; then
  if [[ "${definition}" == *.plist ]]; then
    configured="$(plutil -extract UserName raw -o - "${definition}" 2>/dev/null || true)"
  else
    configured="$(sed -n 's/^User=//p' "${definition}" | head -1)"
  fi
  [[ -n "${configured}" ]] && target_user="${configured}"
fi

target_uid="$(id -u "${target_user}" 2>/dev/null || echo 0)"
target_home="$(home_of "${target_user}")"

# 服务定义里的 PATH（launchd / systemd 都不继承登录 shell 的 PATH）；没有就用保守默认。
target_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if [[ "${definition}" == *.plist && -f "${definition}" ]]; then
  configured="$(plutil -extract EnvironmentVariables.PATH raw -o - "${definition}" 2>/dev/null || true)"
  [[ -n "${configured}" ]] && target_path="${configured}"
fi

# 真正跑这个脚本的人（sudo 下是 SUDO_USER）。用它来回答「别人能用、就这个身份不行」。
invoking_user="${SUDO_USER:-$(id -un)}"
invoking_home="$(home_of "${invoking_user}")"
[[ -z "${invoking_home}" && "${invoking_user}" == "$(id -un)" ]] && invoking_home="${HOME}"

say "运行身份   ${target_user}（uid=${target_uid}，HOME=${target_home:-<未知>}）"
say "服务定义   ${definition:-<无>}$([[ -n "${definition}" && -f "${definition}" ]] || printf '（未安装？按 root 判断）')"

# ---------------------------------------------------------------- 插件候选

# 目标身份会去看的插件路径。`$HOME` 那条只有在**能读到**该 HOME 时才有意义（`/var/root`
# 对普通用户不可读，写进候选只会误导）。
target_candidates() {
  if [[ -n "${target_home}" && -r "${target_home}" ]]; then
    printf '%s\n' "${target_home}/.docker/cli-plugins/docker-compose"
  fi
  local dir
  for dir in "${SYSTEM_PLUGIN_DIRS[@]}"; do
    printf '%s\n' "${dir}/docker-compose"
  done
  # docker 自己所在目录下的 cli-plugins（docker CLI 会扫 `dirname(docker)/cli-plugins`）。
  local docker_bin
  docker_bin="$(env -i "PATH=${target_path}" sh -c 'command -v docker' 2>/dev/null || true)"
  if [[ -n "${docker_bin}" ]]; then
    printf '%s\n' "$(dirname "$(one_hop "${docker_bin}")")/cli-plugins/docker-compose"
  fi
}

# 逐条报告候选状态：存在但不可执行是**最容易漏**的一种（root 能读，但 docker 要求可执行位）。
report_candidates() {
  if [[ -n "${target_home}" && ! -r "${target_home}" ]]; then
    say "             （${target_home}/.docker/cli-plugins 对当前用户不可读；sudo 跑才能看到）"
  fi
  local path target parent
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    parent="$(dirname "${path}")"
    if [[ -L "${path}" && ! -e "${path}" ]]; then
      say "             ${path} → $(readlink "${path}")（断链 ❌）"
    elif [[ -x "${path}" ]]; then
      say "             ${path}（可执行 ✅）"
    elif [[ -e "${path}" ]]; then
      target="$(one_hop "${path}")"
      if [[ "${target}" != "${path}" ]]; then
        say "             ${path} → ${target}（链在，目标不可执行 ❌）"
      else
        say "             ${path}（存在但**不可执行** ❌）"
      fi
    elif [[ -d "${parent}" ]]; then
      say "             ${path}（不存在）"
    else
      say "             ${parent}/（目录不存在）"
    fi
  done < <(target_candidates)
}

# 至少有一个候选可执行（且不是断链）—— 静态结论用。
static_verdict() {
  local path
  while IFS= read -r path; do
    [[ -n "${path}" && -x "${path}" ]] && return 0
  done < <(target_candidates)
  # 读不到目标 HOME 时，不能据此断言「没有」。
  if [[ -n "${target_home}" && ! -r "${target_home}" ]]; then
    return 2
  fi
  return 1
}

# ---------------------------------------------------------------- 真实执行

# 以目标身份真跑一次：能拿到确定答案就走这条（最可靠）。
# 返回 0=可用 1=不可用 2=无法确认（没有权限），并把 docker 的输出留在 DOCKER_ERR。
# 不主动要密码：检查脚本在 CI / 非交互里不能挂住，权限不够就说「需要 sudo」。
DOCKER_ERR=""
try_real() {
  local runner=()
  if [[ "$(id -u)" == "${target_uid}" ]]; then
    runner=(env -i "HOME=${target_home:-/}" "PATH=${target_path}")
  elif sudo -n true 2>/dev/null; then
    runner=(sudo -n env -i "HOME=${target_home:-/}" "PATH=${target_path}")
  else
    return 2
  fi
  local out
  if out="$("${runner[@]}" docker compose version 2>&1)"; then
    say "实测       docker compose 可用：$(printf '%s' "${out}" | head -1)"
    return 0
  fi
  DOCKER_ERR="$(printf '%s' "${out}" | head -3 | tr '\n' ' ')"
  return 1
}

# ---------------------------------------------------------------- 修复

# 挑一个**真的能执行**的 compose 二进制。顺序：
#   1. 被 sudo 代管的那个人（SUDO_USER）在用的 —— 本机能跑，是最好证据；
#   2. 已知绝对路径（OrbStack / Homebrew / /usr/local）；
#   3. 目标身份自己 HOME 里的（最后考虑：它可能就是坏的那个）。
find_compose_binary() {
  local candidate resolved
  local -a candidates=()
  [[ -n "${invoking_home}" && "${invoking_user}" != "${target_user}" ]] &&
    candidates+=("${invoking_home}/.docker/cli-plugins/docker-compose")
  candidates+=("${KNOWN_COMPOSE_BINARIES[@]}")
  [[ -n "${target_home}" ]] && candidates+=("${target_home}/.docker/cli-plugins/docker-compose")
  if command -v docker-compose >/dev/null 2>&1; then
    candidates+=("$(command -v docker-compose)")
  fi
  for candidate in "${candidates[@]}"; do
    [[ -e "${candidate}" ]] || continue
    resolved="$(one_hop "${candidate}")"
    # 关键：**必须可执行**。root 对任何文件都可读，链一个不可执行的过去等于没修。
    if [[ -x "${resolved}" ]]; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  done
  return 1
}

# 需要 root 的动作：已经是 root 就直接做，免密 sudo 就代劳，两者都没有就返回 2。
run_root() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n "$@"
  else
    return 2
  fi
}

do_fix() {
  local binary
  if ! binary="$(find_compose_binary)"; then
    echo "错误：本机找不到**可执行**的 docker-compose，无法自动补（先装 Docker Compose）。" >&2
    return 1
  fi
  if ! run_root true; then
    # 没有 root 也不代要密码：把现成命令交给人执行（脚本不能挂住等输密码）。
    say "修复       需要 root，请手动执行："
    say "             sudo mkdir -p ${FIX_DEST_DIR}"
    say "             sudo ln -sfn ${binary} ${FIX_DEST_DIR}/docker-compose"
    return 1
  fi
  say "修复       把 ${binary} 链到 ${FIX_DEST_DIR}/docker-compose"
  run_root mkdir -p "${FIX_DEST_DIR}"
  run_root ln -sfn "${binary}" "${FIX_DEST_DIR}/docker-compose"
  say "修复       完成（系统级目录对所有身份生效，不随 HOME 变）"
}

# ---------------------------------------------------------------- 主流程

real_rc=0
try_real || real_rc=$?

static_rc=""
case "${real_rc}" in
  0) concl "OK：${target_user} 身份可以跑 docker compose"; exit 0 ;;
  2)
    static_rc=0
    static_verdict || static_rc=$?
    case "${static_rc}" in
      0) concl "OK：${target_user} 的插件路径里有可执行的 docker-compose（未实测）"; exit 0 ;;
      2)
        # 无法确认（读不到目标 HOME、也没有密码）：--fix 仍然往下走（幂等，且正是
        # 「确认不了」时最该把它变成确定的东西）；否则只报告、不妄下结论。
        if [[ "${FIX}" != "1" ]]; then
          say "候选       目标身份的插件路径："
          report_candidates
          concl "未知：读不到 ${target_home:-目标用户的 HOME}，需要 sudo 真跑一次（sudo dev/check-gwlinkd-compose.sh）"
          exit 3
        fi
        ;;
    esac
    ;;
esac

# 到这里：确认不可用（实测失败 / 静态判定必然失败 / --fix 请求但无法确认）。
if [[ "${static_rc}" != "2" ]]; then
  say "候选       目标身份的插件路径："
  report_candidates
  say "实测报错   ${DOCKER_ERR:-（未实测）}"
  say "影响       gops run start/stop、租户绑定生效、升级里的整栈重启"
  # 只有「别的身份能用」时才说这句，且指的是**真正跑脚本的人**（sudo 下是 SUDO_USER）。
  if [[ "${invoking_user}" != "${target_user}" && -x "${invoking_home}/.docker/cli-plugins/docker-compose" ]]; then
    say "对照       ${invoking_user} 是能用的（${invoking_home}/.docker/cli-plugins）—— 差别只在发现路径 / 可执行位"
  fi
else
  say "结论       无法确认 ${target_user} 能不能跑；无论如何先把插件放到系统级目录（幂等操作）"
fi

if [[ "${FIX}" == "1" ]]; then
  if ! do_fix; then
    exit 1 # do_fix 已经打印了现成命令（或确实找不到可执行文件），不重复唠叨。
  fi
  real_rc=0
  try_real || real_rc=$?
  case "${real_rc}" in
    0) concl "OK：修复后 ${target_user} 身份可以跑 docker compose"; exit 0 ;;
    1)
      echo "修复后实测仍失败：${DOCKER_ERR}" >&2
      exit 1
      ;;
    *)
      say "修复已落地，但无法以 ${target_user} 身份验证（用 sudo 重跑本脚本）"
      exit 3
      ;;
  esac
fi

concl "FAIL：${target_user} 身份跑不了 docker compose（修：sudo dev/check-gwlinkd-compose.sh --fix）"
say "           或手工：sudo mkdir -p ${FIX_DEST_DIR} && \\"
say "                   sudo ln -sfn <可执行的 docker-compose> ${FIX_DEST_DIR}/docker-compose"
exit 1
