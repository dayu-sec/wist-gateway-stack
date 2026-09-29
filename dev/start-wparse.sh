#!/usr/bin/env bash
# 启动 wist-gateway 数据平台（wparse，接收/解析 Agent 数据）。
#
# 使用同目录 bin/（dev/bin）下自带的 wparse 二进制（版本与 ../data-plane 工程配套）。
# 工程本体在 ../data-plane（开发态与发布态共用的唯一来源）。
# 用法：
#   ./start-wparse.sh               # 后台常驻，pid/log 落 data/logs/
#   ./start-wparse.sh --foreground  # 前台运行（联调看日志）
# 停止：./stop-wparse.sh
#
# 可覆盖环境变量：
#   WPARSE_BIN           wparse 可执行文件路径（默认 ./bin/wparse）
#   WPARSE_WORK_ROOT     工程根目录（默认 ../data-plane）
#   WPARSE_VM_ENDPOINT   VictoriaMetrics 导入端点（默认 http://127.0.0.1:18429）
#   WPARSE_GATEWAY_ENDPOINT  网关内部接入端点（默认 http://127.0.0.1:3001，agent-facts sink 用）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="${WPARSE_WORK_ROOT:-${SCRIPT_DIR}/../data-plane}"
# 绝对化：下面要拿这个路径去问 docker（按宿主路径筛挂载它的容器）
WORK_ROOT_ABS="$(cd "${WORK_ROOT}" 2>/dev/null && pwd || printf '%s' "${WORK_ROOT}")"
BIN_DIR="$(cd "${SCRIPT_DIR}/bin" && pwd)"
WPARSE="${WPARSE_BIN:-${BIN_DIR}/wparse}"
export WPARSE_VM_ENDPOINT="${WPARSE_VM_ENDPOINT:-http://127.0.0.1:18429}"
export WPARSE_GATEWAY_ENDPOINT="${WPARSE_GATEWAY_ENDPOINT:-http://127.0.0.1:3001}"

CONF_FILE="${WORK_ROOT}/conf/wparse.toml"
LOG_DIR="${WORK_ROOT}/data/logs"
LOCK="${WORK_ROOT}/.run/.wparse.lock"
mkdir -p "$(dirname "${LOCK}")"

# 单实例保障：锁在运行态的 .run/ 下（<work-root>/.run/.wparse.lock）。
# 引擎自身没有单实例保护（同名 work root 起两个会互写 .run/ 与输出），发布态由容器
# entrypoint 的 flock 持锁（见 sys/docker-compose.yml），这里用 python3 的 fcntl 拿同一把。
# 锁 fd 设为可继承：Python 默认 O_CLOEXEC，不设的话 exec 后锁就没了。
LOCK_PY=$(cat <<'PY'
import fcntl, os, sys
lock, cmd = sys.argv[1], sys.argv[2:]
handle = open(lock, "a")
os.set_inheritable(handle.fileno(), True)
try:
    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.stderr.write(
        "[wparse] 另一个 wparse 引擎正持有 " + lock + "：同一 work root 只能起一份\n"
        "[wparse] 排查：pgrep -fl 'wparse daemon'；gops sys status\n"
    )
    sys.exit(75)
os.execv(cmd[0], cmd)
PY
)
lock_exec() { exec python3 -c "${LOCK_PY}" "${LOCK}" "$@"; }

if [[ ! -x "${WPARSE}" ]]; then
  echo "wparse binary not found or not executable: ${WPARSE}" >&2
  echo "expect one at ${BIN_DIR}/wparse (dev/bin/wparse)" >&2
  exit 1
fi
if [[ ! -f "${CONF_FILE}" ]]; then
  echo "missing wparse config: ${CONF_FILE}" >&2
  exit 1
fi
mkdir -p "${LOG_DIR}"

start_daemon() {
  lock_exec "${WPARSE}" daemon --work-root "${WORK_ROOT}"
}

if [[ "${1:-}" == "--foreground" ]]; then
  echo "wparse foreground: ${WPARSE} daemon --work-root ${WORK_ROOT}"
  start_daemon
fi

PIDFILE="${LOG_DIR}/wparse.pid"
if [[ -f "${PIDFILE}" ]]; then
  OLD_PID="$(cat "${PIDFILE}")"
  if kill -0 "${OLD_PID}" 2>/dev/null; then
    echo "wparse already running (pid=${OLD_PID}, ${PIDFILE})" >&2
    exit 1
  fi
  echo "removing stale pidfile ${PIDFILE}" >&2
  rm -f "${PIDFILE}"
fi

# 跨侧兜底：容器与宿主**不共享 flock**（macOS 上 work root 是 virtiofs，guest 内的 flock
# 不落到宿主内核对同一个 inode 的锁表，实测：容器持锁时宿主能拿到），所以宿主侧额外问一句
# docker：有没有容器正挂着这个 work root。（反方向做不到：容器里看不到宿主进程。）
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  BUSY="$(docker ps --filter "volume=${WORK_ROOT_ABS}" --format '{{.Names}}' 2>/dev/null | head -3 | tr '\n' ' ')"
  if [[ -n "${BUSY}" ]]; then
    echo "已有容器挂着这个 work root（${BUSY}），不能同时起宿主实例：" >&2
    echo "  同一 work root 只能一个引擎；要停容器：gops sys stop" >&2
    exit 75
  fi
fi

nohup python3 -c "${LOCK_PY}" "${LOCK}" "${WPARSE}" daemon --work-root "${WORK_ROOT}" >>"${LOG_DIR}/wparse-daemon.log" 2>&1 &
echo $! >"${PIDFILE}"

# 起来后确认真的活着（最常见的原因是锁冲突：同一 work root 已有引擎）
sleep 1
if ! kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
  echo "wparse 启动失败，最近日志：" >&2
  tail -3 "${LOG_DIR}/wparse-daemon.log" >&2
  rm -f "${PIDFILE}"
  exit 1
fi

echo "wparse started pid=$(cat "${PIDFILE}")"
echo "  binary    : ${WPARSE}"
echo "  work-root : ${WORK_ROOT}"
echo "  stdout log: ${LOG_DIR}/wparse-daemon.log"
echo "  engine log: ${LOG_DIR}/wparse.log"
echo "  stop      : ${SCRIPT_DIR}/stop-wparse.sh"
