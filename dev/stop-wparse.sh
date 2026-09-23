#!/usr/bin/env bash
# 停止 ../data-plane 的 wparse 后台实例（配合 start-wparse.sh）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="${WPARSE_WORK_ROOT:-${SCRIPT_DIR}/../data-plane}"
PIDFILE="${WORK_ROOT}/data/logs/wparse.pid"

if [[ ! -f "${PIDFILE}" ]]; then
  echo "wparse not running (no pidfile ${PIDFILE})"
  exit 0
fi

PID="$(cat "${PIDFILE}")"
if [[ ! "${PID}" =~ ^[0-9]+$ ]]; then
  echo "pidfile 内容不是 pid（${PID}），直接删掉：${PIDFILE}" >&2
  rm -f "${PIDFILE}"
  exit 1
fi
# 只要这个 pid 还查得到，就要求它确实是 wparse：pidfile 可能被别的进程写过
# （典型：容器把 pid=1 写进共享的 work root 时，盲 kill 会去杀 launchd）。
CMD="$(ps -p "${PID}" -o command= 2>/dev/null || true)"
if [[ -z "${CMD}" ]]; then
  echo "wparse not running (stale pidfile pid=${PID})"
  rm -f "${PIDFILE}"
  exit 0
fi
if [[ "${CMD}" != *wparse* ]]; then
  echo "pidfile 里的 pid=${PID} 不是 wparse 进程，拒绝 kill：$(printf '%.60s' "${CMD}")" >&2
  rm -f "${PIDFILE}"
  exit 1
fi
kill "${PID}"
echo "stopped wparse pid=${PID}"
rm -f "${PIDFILE}"
