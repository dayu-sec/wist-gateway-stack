#!/usr/bin/env bash
# 启动 wist-gateway 控制面后端（https://127.0.0.1:3000），开发态。
#
# 只管 gateway：前端用 ./dev/start-web.sh，两者一起起用 ./dev/start-svc.sh。
# agent 数据由独立启动的 wist-agentd 上报到 gateway。
# VictoriaMetrics（18429）请先通过 ./dev/start-vm.sh 起，数据面用
# ./dev/start-wparse.sh 起。
#
# 用法：
#   ./dev/start-gateway.sh
#
# 可覆盖 env：WIST_GATEWAY_HOME / GATEWAY_PIDFILE / SKIP_BUILD
#
# 启动前会 cargo build 两个 crate（wist-gateway / wist-agentd），确保跑的是当前源码；
# 设 SKIP_BUILD=1 可跳过。
#
# 本脚本会把自己的 pid 写到 GATEWAY_PIDFILE（默认 /tmp/wist-gateway.pid），
# 供 ./dev/stop-svc.sh 精确停止——杀本脚本会触发 EXIT trap 一并停掉 gateway。
#
# 网关持久数据（wist-gateway.toml + state/：SQLite 库 / TLS / 签名密钥）默认落在
# ${HOME}/.wist-gateway，与 .run（运行期临时产物）分离；清 .run 不再清掉 agents 注册表。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 本脚本位于 wist-gateway-stack/dev/：
#   ROOT_DIR   = 各 crate 的父目录（x-topology）
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GW_CRATE="${ROOT_DIR}/wist-gateway"
AGENTD_CRATE="${ROOT_DIR}/wist-agentd"
# 模型仓（创作源）。策展数据（内容目录等）都从这里拷到网关配置目录，
# 而不是把运行期配置直接指向模型仓（详见 ensure_content_files）。
WIST_DESIGN_DIR="${WIST_DESIGN_DIR:-${ROOT_DIR}/../wist-design}"

# 网关持久数据（配置 + state）落在这里；可用 WIST_GATEWAY_HOME 覆盖。
GW_HOME="${WIST_GATEWAY_HOME:-${HOME}/.wist-gateway}"
GATEWAY_PIDFILE="${GATEWAY_PIDFILE:-/tmp/wist-gateway.pid}"
SKIP_BUILD="${SKIP_BUILD:-0}"

GATEWAY_PID=""

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "${GATEWAY_PID}" ]] && kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    kill "${GATEWAY_PID}" 2>/dev/null || true
    wait "${GATEWAY_PID}" 2>/dev/null || true
  fi
  rm -f "${GATEWAY_PIDFILE}"
  echo
  echo "已停止 gateway 进程。"
}
trap cleanup EXIT

# 构建两个 Rust crate（wist-gateway / wist-agentd）。
#
# 开发态**每次都构建**：cargo 增量编译在无改动时近乎瞬时，而「二进制已存在就跳过」
# 会让改了源码后跑起来的仍是旧二进制（典型症状：新接口返回 404，极易误判成服务未启动）。
# 设 SKIP_BUILD=1 可跳过（例如故意要跑现有产物）。
build_rust_binaries() {
  echo "== 1. 构建 Rust 二进制（wist-gateway / wist-agentd）=="
  if [[ "${SKIP_BUILD}" == "1" ]]; then
    echo "  已跳过（SKIP_BUILD=1）"
  else
    require_cmd cargo
    # 不重定向输出：编译错误必须让操作者看见，否则只剩一句“启动失败”。
    cargo build --manifest-path "${GW_CRATE}/Cargo.toml"
    cargo build --manifest-path "${AGENTD_CRATE}/Cargo.toml"
  fi
  # 跳构建或构建产物异常时，这里提前报清楚，而不是等到启动时才失败。
  local bin
  for bin in \
    "${GW_CRATE}/target/debug/wist-gateway" \
    "${AGENTD_CRATE}/target/debug/wist-agentd"; do
    if [[ ! -x "${bin}" ]]; then
      echo "缺少可执行文件：${bin}" >&2
      echo "  去掉 SKIP_BUILD 重跑本脚本以构建。" >&2
      exit 1
    fi
  done
}

# 确保网关的 TLS 自签证书存在，且是**合法叶证书**。
#
# 这张证书既是服务端证书，又被回填成 Agent 的信任锚（见下方 trust_bundle 回填）。两个角色要求不同：
#   - 服务端：必须是合法叶证书（basicConstraints: critical,CA:FALSE，keyUsage 含 digitalSignature/
#     keyEncipherment，extendedKeyUsage: serverAuth）。`openssl req -x509` 的旧默认会打上 `CA:TRUE`，
#     rustls/webpki 便以 CaUsedAsEndEntity 拒收它作服务端证书 —— Agent 侧表现为 TLS 握手失败，
#     日志里是 `wist-agentd status report failed: error sending request for url (...)`。
#   - 信任锚：不要求是 CA，webpki 接受非 CA 的自签证书作锚，所以一张证书两用可行。
#     代价是「换证书 = 换信任锚」，Agent 必须重新获取（见 ./dev/re-enroll.sh）。
ensure_admin_tls_cert() {
  local state_dir="$1"
  local cert="${state_dir}/admin-tls.crt.pem"
  require_cmd openssl
  if [[ -f "${cert}" ]] && cert_is_end_entity "${cert}"; then
    return
  fi
  if [[ -f "${cert}" ]]; then
    echo "  已有 TLS 证书不是合法叶证书（basicConstraints 非 CA:FALSE），重新生成"
    echo "    注意：证书已更换，Agent 侧内嵌的信任锚随之失效，需重跑安装（install.sh 会用新的"
    echo "    initial-config 重写 agentd.toml；仅 re-enroll.sh 不会刷新 trust_bundle）"
  else
    echo "  生成网关自签 TLS 证书（叶证书形态）"
  fi
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${state_dir}/admin-tls.key.pem" \
    -out "${cert}" -days 365 -subj "/CN=localhost" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
}

cert_is_end_entity() {
  openssl x509 -in "$1" -noout -text 2>/dev/null \
    | grep -A1 "Basic Constraints" | grep -q "CA:FALSE"
}

generate_gateway_config() {
  echo "== 2. 生成网关自管配置（wist-gateway.toml，含 admin token）=="
  local gw_bin="${GW_CRATE}/target/debug/wist-gateway"
  mkdir -p "${GW_HOME}"
  "${gw_bin}" init-config "${GW_HOME}/wist-gateway.toml"
  echo "  wist-gateway.toml 已生成：${GW_HOME}/wist-gateway.toml"
}

# 把模型仓的采集内容（catalog/packs/templates）拷到**配置目录下**，并把相对路径写进配置。
#
# 为什么不把配置直接指向模型仓：那三个文件是**创作源**，而且在配置里写的是**相对配置文件**
# 的路径（配置在 ${GW_HOME}），`../../wist-design/...` 根本落不到模型仓。
# 部署约定是「拷过来、就近引用」—— 与 [purpose]/[discovery] 一致。
# 找不到模型仓（未带仓部署）就跳过：内容留空，网关照常起（只是不提供模板展开）。
ensure_content_files() {
  local src="${WIST_DESIGN_DIR}/jumo/model/content"
  if [[ ! -d "${src}" ]]; then
    echo "  未找到模型仓内容目录，跳过内容装载：${src}"
    return
  fi
  local dst="${GW_HOME}/content"
  mkdir -p "${dst}"
  local name
  for name in catalog.toml packs.toml templates.toml; do
    cp -f "${src}/${name}" "${dst}/${name}"
  done
  # 把 [content] 段重写成指向刚拷过来的三份文件（先移除旧段再追加，保证幂等）。
  python3 - "${GW_HOME}/wist-gateway.toml" <<'PY'
import sys

path = sys.argv[1]
with open(path) as handle:
    lines = handle.readlines()

kept = []
skipping = False
for line in lines:
    if line.strip() == "[content]":
        skipping = True
        continue
    if skipping and line.startswith("["):
        skipping = False
    if not skipping:
        kept.append(line)

if kept and not kept[-1].endswith("\n"):
    kept[-1] += "\n"
kept.append(
    "\n[content]\n"
    'catalog_file = "content/catalog.toml"\n'
    'packs_file = "content/packs.toml"\n'
    'templates_file = "content/templates.toml"\n'
)
with open(path, "w") as handle:
    handle.writelines(kept)
PY
  echo "  content 已就绪：${dst}"
}

start_gateway() {
  echo "== 3. 启动 wist-gateway（https://127.0.0.1:3000）=="
  require_cmd lsof
  # 独占 3000：清掉端口上的残留 wist-gateway，避免前端打到旧实例。
  local stale_gw
  stale_gw="$(lsof -ti tcp:3000 2>/dev/null || true)"
  if [[ -n "${stale_gw}" ]]; then
    echo "  清理 3000 端口残留进程：${stale_gw}"
    kill ${stale_gw} 2>/dev/null || true
    sleep 0.5
  fi
  local gw_bin="${GW_CRATE}/target/debug/wist-gateway"
  local state_dir="${GW_HOME}/state"
  mkdir -p "${state_dir}"
  ensure_admin_tls_cert "${state_dir}"
  # wist-gateway 启动校验 agent.package_file 存在；指向仓库 agentd 二进制。
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

# ── 主流程 ──

require_cmd python3

echo "启动 wist-gateway 控制面后端（开发态）"
echo "  gateway: https://127.0.0.1:3000"
echo "  前端：./dev/start-web.sh；两件套一起：./dev/start-svc.sh"
echo "  前置：VictoriaMetrics（./dev/start-vm.sh）、数据面（./dev/start-wparse.sh）"
echo

build_rust_binaries

if [[ -f "${GW_HOME}/wist-gateway.toml" ]]; then
  echo "复用已有网关配置：${GW_HOME}/wist-gateway.toml"
else
  generate_gateway_config
fi
ensure_content_files
echo $$ >"${GATEWAY_PIDFILE}"
start_gateway

echo
echo "网关已启动，按 Ctrl+C 停止。"
echo "  gateway ：https://127.0.0.1:3000"
echo "  日志    ：/tmp/wist-gateway-server.log"
echo "  pid     ：${GATEWAY_PIDFILE}"
echo
while :; do sleep 60; done
