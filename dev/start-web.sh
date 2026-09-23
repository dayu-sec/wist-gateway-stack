#!/usr/bin/env bash
# 启动 wist-gateway-web 前端开发服务器（默认 http://127.0.0.1:5174）。
#
# 只起前端：适合网关已经在跑、只想单独起/重启前端的场景——例如另一个终端跑了
# ./dev/start-gateway.sh，或前端改崩了要单独重启。
# 整栈一起起用 ./dev/start-svc.sh（它会调本脚本），不用手动执行。
#
# 用法：
#   ./dev/start-web.sh                # 后台常驻（pid/log 见输出）
#   ./dev/start-web.sh --foreground   # 前台运行，直接看 vite 输出
#   ./dev/stop-web.sh                 # 停止
#
# 可覆盖 env：
#   WEB_URL                          前端监听地址（默认 http://127.0.0.1:5174）
#   WEB_DIR                          wist-gateway-web 目录（默认 ../wist-gateway-web）
#   WEB_LOG / WEB_PIDFILE            日志与 pid 文件（默认 /tmp 下）
#   WARP_INSIGHT_WEB_PROXY_TARGET    /api 反代目标（vite.config.ts 读取，默认 https://localhost:3000）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 本脚本位于 wist-gateway-stack/dev/：
#   ROOT_DIR = 各 crate 的父目录（x-topology）
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WEB_DIR="${WEB_DIR:-${ROOT_DIR}/wist-gateway-web}"

WEB_URL="${WEB_URL:-http://127.0.0.1:5174}"
WEB_LOG="${WEB_LOG:-/tmp/wist-gateway-web.log}"
WEB_PIDFILE="${WEB_PIDFILE:-/tmp/wist-gateway-web.pid}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

web_status() {
  curl -s -o /dev/null -w "%{http_code}" "${WEB_URL%/}/" || true
}

wait_until() {
  # wait_until <描述> <cmd...>
  local desc="$1"
  shift
  echo "等待 ${desc} 就绪..."
  for _ in {1..100}; do
    if "$@" >/dev/null 2>&1; then
      echo "  ${desc} 就绪"
      return 0
    fi
    sleep 0.2
  done
  echo "  ${desc} 未就绪（日志 ${WEB_LOG}）" >&2
  return 1
}

start_dev() {
  cd "${WEB_DIR}"
  exec npm run dev -- --host "${HOST}" --port "${PORT}" --strictPort
}

require_cmd curl
require_cmd python3
require_cmd npm

if [[ ! -d "${WEB_DIR}" ]]; then
  echo "wist-gateway-web 目录不存在：${WEB_DIR}" >&2
  echo "  可用 WEB_DIR 覆盖（默认 ${ROOT_DIR}/wist-gateway-web）" >&2
  exit 1
fi
if [[ ! -d "${WEB_DIR}/node_modules" ]]; then
  echo "wist-gateway-web 依赖缺失：${WEB_DIR}/node_modules（先 cd 到该目录执行 npm install）" >&2
  exit 1
fi

HOST="$(python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').hostname or '127.0.0.1')")"
PORT="$(python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').port or 80)")"

if [[ "${1:-}" == "--foreground" ]]; then
  echo "wist-gateway-web foreground: npm run dev -- --host ${HOST} --port ${PORT} --strictPort"
  start_dev
fi

# 已由本脚本启动：幂等返回，不重复起第二个实例（strictPort 下也会失败）。
if [[ -f "${WEB_PIDFILE}" ]]; then
  OLD_PID="$(cat "${WEB_PIDFILE}")"
  if kill -0 "${OLD_PID}" 2>/dev/null; then
    echo "wist-gateway-web already running (pid=${OLD_PID}, ${WEB_PIDFILE})"
    echo "  url : ${WEB_URL}"
    echo "  log : ${WEB_LOG}"
    echo "  stop: ${SCRIPT_DIR}/stop-web.sh"
    exit 0
  fi
  echo "removing stale pidfile ${WEB_PIDFILE}" >&2
  rm -f "${WEB_PIDFILE}"
fi

# 端口上已有前端在响应（例如 ./dev/start-svc.sh 起的）：复用。
# 这里刻意不写 pidfile —— 不是本脚本启动的进程，交给 stop-web.sh 的端口兜底处理。
if [[ "$(web_status)" == "200" ]]; then
  echo "wist-gateway-web 已在运行（${WEB_URL}），复用。"
  exit 0
fi

# 子 shell + exec：$! 即 npm 的 pid。
(
  cd "${WEB_DIR}"
  exec nohup npm run dev -- --host "${HOST}" --port "${PORT}" --strictPort \
    >"${WEB_LOG}" 2>&1
) &
echo $! >"${WEB_PIDFILE}"

echo "wist-gateway-web started pid=$(cat "${WEB_PIDFILE}")"
echo "  dir  : ${WEB_DIR}"
echo "  url  : ${WEB_URL}"
echo "  log  : ${WEB_LOG}"
echo "  stop : ${SCRIPT_DIR}/stop-web.sh"

if wait_until "wist-gateway-web" web_status; then
  exit 0
fi
exit 1
