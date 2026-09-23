#!/usr/bin/env bash
# 停止 wist-gateway-web 前端开发服务器（配合 start-web.sh）。
#
# 两步：
#   1) 按 pidfile 停 start-web.sh 启动的实例；
#   2) 端口兜底：npm 会再 fork 出 vite，只 kill npm 可能把 vite 留成孤儿继续占端口，
#      因此端口上仍在监听的一并清理（与 start-gateway.sh 清理 3000 端口同一口径）。
#      注意：这一步也会停掉 ./dev/start-svc.sh 启动的前端。
#
# 用同一个 WEB_URL / WEB_PIDFILE（默认 http://127.0.0.1:5174、/tmp/wist-gateway-web.pid）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_URL="${WEB_URL:-http://127.0.0.1:5174}"
WEB_PIDFILE="${WEB_PIDFILE:-/tmp/wist-gateway-web.pid}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd python3
require_cmd lsof

PORT="$(python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').port or 80)")"

if [[ -f "${WEB_PIDFILE}" ]]; then
  PID="$(cat "${WEB_PIDFILE}")"
  if kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}" 2>/dev/null || true
    echo "stopped wist-gateway-web pid=${PID}"
  else
    echo "wist-gateway-web not running (stale pidfile pid=${PID})"
  fi
  rm -f "${WEB_PIDFILE}"
else
  echo "wist-gateway-web not running (no pidfile ${WEB_PIDFILE})"
fi

leftover="$(lsof -ti "tcp:${PORT}" 2>/dev/null || true)"
if [[ -n "${leftover}" ]]; then
  echo "清理 ${PORT} 端口残留进程：${leftover}"
  kill ${leftover} 2>/dev/null || true
fi
