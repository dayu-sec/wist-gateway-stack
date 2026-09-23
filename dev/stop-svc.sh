#!/usr/bin/env bash
# 停止开发态全栈（配合 start-svc.sh）。
#
# 覆盖四个组件：控制面 gateway（3000）、前端 web（5174）、wparse 数据面、VictoriaMetrics。
# 各组件仍可单独停（stop-web.sh / stop-wparse.sh / stop-vm.sh），本脚本按
# 「启动的逆序」依次调用，并对端口做兜底清理。
#
# 可覆盖 env（与 start-svc.sh 对应，想保留某个组件就跳过它）：
#   SKIP_WEB=1       不停前端 web
#   SKIP_WPARSE=1    不停数据面
#   SKIP_VM=1        不停 VictoriaMetrics（例如只想停控制面、保留指标采集）
#
# 说明：
#   - 控制面正常退出方式是前台 Ctrl+C；若你把 start-svc.sh 放到后台跑，这里靠端口兜底停它。
#   - VictoriaMetrics 数据在 docker 卷里，stop 不会丢指标。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GATEWAY_PORT="${GATEWAY_PORT:-3000}"
GATEWAY_PIDFILE="${GATEWAY_PIDFILE:-/tmp/wist-gateway.pid}"
WEB_URL="${WEB_URL:-http://127.0.0.1:5174}"
SKIP_WEB="${SKIP_WEB:-0}"
SKIP_WPARSE="${SKIP_WPARSE:-0}"
SKIP_VM="${SKIP_VM:-0}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}
require_cmd lsof

echo "停止开发态全栈（gateway → web → wparse → VictoriaMetrics）"
echo

echo "== 1. 控制面 gateway（${GATEWAY_PORT}）=="
# 先按 pidfile 停前台包装 start-gateway.sh（它的 EXIT trap 会一并停掉 gateway）；
# 再对端口做兜底，处理把 start-svc.sh 放后台、或包装已不在的情况。
stopped_something=0
if [[ -f "${GATEWAY_PIDFILE}" ]]; then
  wrapper_pid="$(cat "${GATEWAY_PIDFILE}")"
  if kill -0 "${wrapper_pid}" 2>/dev/null; then
    echo "  停止控制面包装 start-gateway.sh（pid=${wrapper_pid}）"
    kill "${wrapper_pid}" 2>/dev/null || true
    sleep 1
    stopped_something=1
  else
    echo "  清理 stale pidfile（pid=${wrapper_pid} 已不在）"
  fi
  rm -f "${GATEWAY_PIDFILE}"
fi
gateway_pids="$(lsof -ti "tcp:${GATEWAY_PORT}" 2>/dev/null || true)"
if [[ -n "${gateway_pids}" ]]; then
  echo "  停止 gateway 进程：${gateway_pids}"
  kill ${gateway_pids} 2>/dev/null || true
  stopped_something=1
fi
if [[ "${stopped_something}" == "0" ]]; then
  echo "  未在运行（无 pidfile、端口空闲）。"
fi
echo

# stop-web.sh 需要同一个 WEB_URL 才能定位端口。
echo "== 2. 前端 web（${WEB_URL}）=="
if [[ "${SKIP_WEB}" == "1" ]]; then
  echo "  已跳过（SKIP_WEB=1）"
else
  WEB_URL="${WEB_URL}" "${SCRIPT_DIR}/stop-web.sh"
fi
echo

echo "== 3. wparse 数据面 =="
if [[ "${SKIP_WPARSE}" == "1" ]]; then
  echo "  已跳过（SKIP_WPARSE=1）"
else
  "${SCRIPT_DIR}/stop-wparse.sh"
fi
echo

echo "== 4. VictoriaMetrics =="
if [[ "${SKIP_VM}" == "1" ]]; then
  echo "  已跳过（SKIP_VM=1）"
elif ! command -v docker >/dev/null 2>&1; then
  echo "  未安装 docker，跳过。"
elif ! docker info >/dev/null 2>&1; then
  echo "  容器后端未运行，说明 VictoriaMetrics 也没在跑，跳过。"
else
  # 复用 stop-vm.sh，避免两处各写一份 compose 调用。
  "${SCRIPT_DIR}/stop-vm.sh"
fi
