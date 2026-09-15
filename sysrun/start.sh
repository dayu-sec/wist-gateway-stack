#!/usr/bin/env bash
# 启动 wist-gateway 控制面（3000）+ wist-gateway-web 前端（5174），开发态。
#
# 只负责控制面两件套；agent 数据由独立启动的 wist-agentd 上报到 gateway。
# VictoriaMetrics（18429）请先通过 ./sysrun/start-vm.sh 起，数据面用
# ./sysrun/data-plane/start-wparse.sh 起。
#
# 用法：
#   ./sysrun/start.sh
#
# 可覆盖 env：WEB_URL / WIST_GATEWAY_HOME / SKIP_WEB
#
# 网关持久数据（wist-gateway.toml + state/：store / TLS / 签名密钥）默认落在
# ${HOME}/.wist-gateway，与 .run（运行期临时产物）分离；清 .run 不再清掉 agents 注册表。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 本脚本位于 wist-gateway-stack/sysrun/：
#   ROOT_DIR   = 各 crate 的父目录（x-topology）
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GW_CRATE="${ROOT_DIR}/wist-gateway"
AGENTD_CRATE="${ROOT_DIR}/wist-agentd"
WEB_DIR="${ROOT_DIR}/wist-gateway-web"

# 网关持久数据（配置 + state）落在这里；可用 WIST_GATEWAY_HOME 覆盖。
GW_HOME="${WIST_GATEWAY_HOME:-${HOME}/.wist-gateway}"
WEB_URL="${WEB_URL:-http://127.0.0.1:5174}"
SKIP_WEB="${SKIP_WEB:-0}"

GATEWAY_PID=""
WEB_PID=""

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "${WEB_PID}" ]] && kill -0 "${WEB_PID}" 2>/dev/null; then
    kill "${WEB_PID}" 2>/dev/null || true
    wait "${WEB_PID}" 2>/dev/null || true
  fi
  if [[ -n "${GATEWAY_PID}" ]] && kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    kill "${GATEWAY_PID}" 2>/dev/null || true
    wait "${GATEWAY_PID}" 2>/dev/null || true
  fi
  echo
  echo "已停止 gateway / web 进程。"
}
trap cleanup EXIT

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
  echo "  ${desc} 未就绪。" >&2
  return 1
}

generate_gateway_config() {
  echo "== 1. 生成网关自管配置（wist-gateway.toml，含 admin token）=="
  local gw_bin="${GW_CRATE}/target/debug/wist-gateway"
  if [[ ! -x "${gw_bin}" ]]; then
    require_cmd cargo
    cargo build --manifest-path "${GW_CRATE}/Cargo.toml" >/dev/null
  fi
  mkdir -p "${GW_HOME}"
  "${gw_bin}" init-config "${GW_HOME}/wist-gateway.toml"
  echo "  wist-gateway.toml 已生成：${GW_HOME}/wist-gateway.toml"
}

start_gateway() {
  echo "== 2. 启动 wist-gateway（https://127.0.0.1:3000）=="
  require_cmd lsof
  # 独占 3000：清掉端口上的残留 wist-gateway，避免 web 打到旧实例。
  local stale_gw
  stale_gw="$(lsof -ti tcp:3000 2>/dev/null || true)"
  if [[ -n "${stale_gw}" ]]; then
    echo "  清理 3000 端口残留进程：${stale_gw}"
    kill ${stale_gw} 2>/dev/null || true
    sleep 0.5
  fi
  local gw_bin="${GW_CRATE}/target/debug/wist-gateway"
  if [[ ! -x "${gw_bin}" ]]; then
    require_cmd cargo
    cargo build --manifest-path "${GW_CRATE}/Cargo.toml" >/dev/null
  fi
  local state_dir="${GW_HOME}/state"
  mkdir -p "${state_dir}"
  if [[ ! -f "${state_dir}/admin-tls.crt.pem" ]]; then
    require_cmd openssl
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${state_dir}/admin-tls.key.pem" \
      -out "${state_dir}/admin-tls.crt.pem" -days 365 -subj "/CN=localhost" \
      -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
  fi
  # wist-gateway 启动校验 agent.package_file 存在；指向仓库 agentd 二进制，并确保已构建。
  if [[ ! -x "${AGENTD_CRATE}/target/debug/wist-agentd" ]]; then
    require_cmd cargo
    cargo build --manifest-path "${AGENTD_CRATE}/Cargo.toml" >/dev/null
  fi
  sed -i '' "s|^package_file = .*|package_file = \"${AGENTD_CRATE}/target/debug/wist-agentd\"|" "${GW_HOME}/wist-gateway.toml"
  # agent 安装期通过脚本内嵌 trust_bundle（--cacert）校验网关 TLS；
  # dev 用自签证书，直接把该证书本身嵌为信任锚（install.sh 内嵌 CA PEM 不能是占位符）。
  python3 - "${state_dir}/admin-tls.crt.pem" "${GW_HOME}/wist-gateway.toml" <<'PY'
import re, sys
nl = chr(10)
cert = open(sys.argv[1]).read().strip()
path = sys.argv[2]
text = open(path).read()
block = 'trust_bundle = """' + nl + cert + nl + '"""'
text = re.sub(
    r'(?ms)^trust_bundle = (""".*?"""|".*?")\s*\n',
    block + '\n',
    text,
    count=1,
)
open(path, "w").write(text)
PY
  WIST_GATEWAY_CONFIG="${GW_HOME}/wist-gateway.toml" \
    "${gw_bin}" >"/tmp/wist-gateway-server.log" 2>&1 &
  GATEWAY_PID=$!
  echo "  wist-gateway 已启动 (pid=$!)"
}

start_web() {
  echo "== 3. 启动网关管理前端 wist-gateway-web（${WEB_URL}）=="
  if [[ "${SKIP_WEB}" == "1" ]]; then
    echo "  已跳过（SKIP_WEB=1）"
    return
  fi
  if [[ "$(web_status)" == "200" ]]; then
    echo "  wist-gateway-web 已在运行（${WEB_URL}），复用。"
    return
  fi
  require_cmd npm
  local web_dir="${WEB_DIR}"
  if [[ ! -d "${web_dir}/node_modules" ]]; then
    echo "  wist-gateway-web 依赖缺失：${web_dir}/node_modules（先 cd 到该目录执行 npm install）" >&2
    exit 1
  fi
  local host port
  host="$(python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').hostname or '127.0.0.1')")"
  port="$(python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').port or 80)")"
  (
    cd "${web_dir}"
    exec nohup npm run dev -- --host "${host}" --port "${port}" --strictPort \
      >/tmp/wist-gateway-web.log 2>&1
  ) &
  WEB_PID=$!
  echo "  启动 wist-gateway-web：${WEB_URL} (pid=$!)"
  if wait_until "wist-gateway-web" web_status; then
    echo "  wist-gateway-web 就绪"
  else
    echo "  wist-gateway-web 未就绪（日志 /tmp/wist-gateway-web.log）"
    WEB_PID=""
  fi
}

# ── 主流程 ──

require_cmd curl
require_cmd python3

echo "启动 wist-gateway 控制面 + wist-gateway-web 前端（开发态）"
echo "  gateway: https://127.0.0.1:3000"
echo "  web:     ${WEB_URL}（SKIP_WEB=1 可跳过）"
echo "  前置：VictoriaMetrics（./sysrun/start-vm.sh）、数据面（./sysrun/data-plane/start-wparse.sh）"
echo

if [[ -f "${GW_HOME}/wist-gateway.toml" ]]; then
  echo "复用已有网关配置：${GW_HOME}/wist-gateway.toml"
else
  generate_gateway_config
fi
start_gateway
start_web

echo
echo "控制面已启动，按 Ctrl+C 停止。"
echo "  管理页面：${WEB_URL}"
echo "  gateway ：https://127.0.0.1:3000"
echo
while :; do sleep 60; done
