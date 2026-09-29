#!/usr/bin/env bash
# 开发态统一入口：把本地全栈的「起 / 停 / 看」收在一处。
#
# 对应发布态的 `gops sys start|stop|status`（docker compose 起全栈）；开发态用本地二进制，
# 网关持久数据在 `~/.wist-gateway`（发布态另用 `<栈根>/configs/gateway`，两套目录互不影响）。
#
# 用法：
#   ./dev/svc.sh start [组件…] [--no-build] [--dry-run]
#   ./dev/svc.sh stop  [组件…]
#   ./dev/svc.sh status
#
#   组件（不给 = 全部）：vm | wparse | web | gateway（也可写 all）
#
# 同一口径（不再有「有的跳过、有的报错」）：
#   start：先 `cargo build` 一次（wist-gateway + wist-agentd；`--no-build` 或 `SKIP_BUILD=1` 跳过）；
#          每个组件**已在运行则跳过**；按 vm → wparse → web → gateway 顺序；
#          gateway 跑**前台**（Ctrl+C 停），其余后台常驻（不随本脚本退出而停）。
#   stop ：按 start 的**逆序**停；未在跑的是 no-op。
#   status：只读，打印四个组件当前状态。
#
# 例：
#   ./dev/svc.sh start                  # 全栈（日常）
#   ./dev/svc.sh start web              # 只重启前端（gateway 已在跑时）
#   ./dev/svc.sh start gateway --no-build
#   ./dev/svc.sh stop web gateway
#   ./dev/svc.sh status
#
# 可覆盖 env（与旧的分散脚本同口径）：
#   SKIP_BUILD=1 等价 --no-build
#   WIST_GATEWAY_HOME（默认 ~/.wist-gateway）  GATEWAY_PIDFILE  GATEWAY_PORT（覆盖停网关时的端口；默认读配置）
#   WEB_URL  WEB_DIR  WEB_LOG  WEB_PIDFILE  WARP_INSIGHT_WEB_PROXY_TARGET
#   WPARSE_BIN  WPARSE_WORK_ROOT  WPARSE_VM_ENDPOINT  WPARSE_GATEWAY_ENDPOINT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GW_CRATE="${ROOT_DIR}/wist-gateway"
AGENTD_CRATE="${ROOT_DIR}/wist-agentd"
WIST_DESIGN_DIR="${WIST_DESIGN_DIR:-${ROOT_DIR}/../wist-design}"

# ── 控制面 gateway ──
GW_HOME="${WIST_GATEWAY_HOME:-${HOME}/.wist-gateway}"
GATEWAY_PIDFILE="${GATEWAY_PIDFILE:-/tmp/wist-gateway.pid}"
# ── 前端 web ──
WEB_URL="${WEB_URL:-http://127.0.0.1:5174}"
WEB_DIR="${WEB_DIR:-${ROOT_DIR}/wist-gateway-web}"
WEB_LOG="${WEB_LOG:-/tmp/wist-gateway-web.log}"
WEB_PIDFILE="${WEB_PIDFILE:-/tmp/wist-gateway-web.pid}"
# ── 数据面 wparse ──
WPARSE_WORK_ROOT="${WPARSE_WORK_ROOT:-${STACK_ROOT}/data-plane}"
WPARSE_BIN="${WPARSE_BIN:-${SCRIPT_DIR}/bin/wparse}"
WPARSE_PIDFILE="${WPARSE_WORK_ROOT}/data/logs/wparse.pid"
export WPARSE_VM_ENDPOINT="${WPARSE_VM_ENDPOINT:-http://127.0.0.1:18429}"
export WPARSE_GATEWAY_ENDPOINT="${WPARSE_GATEWAY_ENDPOINT:-http://127.0.0.1:3001}"
# ── 观测 VictoriaMetrics（第三方，走 docker compose）──
VM_URL="${VM_URL:-http://127.0.0.1:18429}"
COMPOSE=(docker compose --project-directory "${STACK_ROOT}" -f "${STACK_ROOT}/sys/docker-compose.yml")

usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^#[[:space:]]\{0,1\}//'
}

die() {
  echo "错误：$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

# ────────────────────────────────────────────────────────────────────────────
# VictoriaMetrics（docker compose 里的第三方依赖，无本地二进制）
# ────────────────────────────────────────────────────────────────────────────
vm_up() { curl -s -o /dev/null "${VM_URL%/}/health"; }

wait_vm() {
  echo "  等待 VictoriaMetrics 就绪..."
  local i
  for i in {1..50}; do
    if vm_up; then
      echo "  就绪。"
      return 0
    fi
    sleep 0.2
  done
  echo "  VictoriaMetrics 未就绪（日志：${COMPOSE[*]} logs victoria-metrics）" >&2
  return 1
}

start_vm() {
  echo "== VictoriaMetrics（${VM_URL}）=="
  if vm_up; then
    echo "  已在运行，跳过。"
    return 0
  fi
  # 容器后端没起来时 docker 只会抛原始错误，这里先给出可执行的解决办法。
  if ! docker info >/dev/null 2>&1; then
    echo "  容器后端未运行，VictoriaMetrics 走 docker compose 起不来。" >&2
    echo "  当前 docker context: $(docker context show 2>/dev/null || echo unknown)" >&2
    echo "  启动后端任选其一：orb start ／ open -a Docker ／ colima start" >&2
    echo "  或只起你需要的那几个：./dev/svc.sh start web gateway" >&2
    return 1
  fi
  "${COMPOSE[@]}" up -d victoria-metrics
  wait_vm
}

stop_vm() {
  echo "== VictoriaMetrics =="
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "  docker 不可用 / 容器后端未运行，跳过。"
    return 0
  fi
  "${COMPOSE[@]}" stop victoria-metrics >/dev/null 2>&1 || true
  echo "  已停（数据在 docker 卷里，不丢指标）。"
}

# ────────────────────────────────────────────────────────────────────────────
# wparse 数据面（本地二进制；工程在 ../data-plane，开发态与发布态共用配置）
# ────────────────────────────────────────────────────────────────────────────
wparse_up() {
  [[ -f "${WPARSE_PIDFILE}" ]] || return 1
  kill -0 "$(cat "${WPARSE_PIDFILE}")" 2>/dev/null
}

# 单实例锁：与容器 entrypoint 同一把（<work-root>/.run/.wparse.lock）。引擎自身没有单实例
# 保护，同 work root 起两份会互写 .run/ 与输出。macOS 没有 flock(1)，用 python3 的 fcntl；
# 锁 fd 设成可继承才能在 exec 后存活。
WPARSE_LOCK_PY=$(cat <<'PY'
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

start_wparse() {
  echo "== wparse 数据面 =="
  if wparse_up; then
    echo "  已在运行（pid=$(cat "${WPARSE_PIDFILE}")），跳过。"
    return 0
  fi
  [[ -x "${WPARSE_BIN}" ]] || die "找不到可执行的 wparse：${WPARSE_BIN}（dev/bin/wparse）"
  [[ -f "${WPARSE_WORK_ROOT}/conf/wparse.toml" ]] || die "缺少 wparse 配置：${WPARSE_WORK_ROOT}/conf/wparse.toml"

  local lock="${WPARSE_WORK_ROOT}/.run/.wparse.lock"
  local log_dir="${WPARSE_WORK_ROOT}/data/logs"
  mkdir -p "$(dirname "${lock}")" "${log_dir}"

  # 跨侧兜底：容器与宿主（macOS/virtiofs）不共享 flock，所以宿主侧再问一句 docker ——
  # 有没有容器正挂着同一个 work root。
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local work_abs busy
    work_abs="$(cd "${WPARSE_WORK_ROOT}" 2>/dev/null && pwd || printf '%s' "${WPARSE_WORK_ROOT}")"
    busy="$(docker ps --filter "volume=${work_abs}" --format '{{.Names}}' 2>/dev/null | head -3 | tr '\n' ' ')"
    if [[ -n "${busy}" ]]; then
      die "已有容器挂着这个 work root（${busy}）—— 同一 work root 只能一个引擎；要停容器：gops sys stop"
    fi
  fi

  nohup python3 -c "${WPARSE_LOCK_PY}" "${lock}" "${WPARSE_BIN}" daemon --work-root "${WPARSE_WORK_ROOT}" \
    >>"${log_dir}/wparse-daemon.log" 2>&1 &
  echo $! >"${WPARSE_PIDFILE}"

  # 起来后确认真的活着（最常见的原因是锁冲突）。
  sleep 1
  if ! kill -0 "$(cat "${WPARSE_PIDFILE}")" 2>/dev/null; then
    echo "  wparse 启动失败，最近日志：" >&2
    tail -3 "${log_dir}/wparse-daemon.log" >&2
    rm -f "${WPARSE_PIDFILE}"
    return 1
  fi
  echo "  已启动 (pid=$(cat "${WPARSE_PIDFILE}"))，工程 ${WPARSE_WORK_ROOT}。"
}

stop_wparse() {
  echo "== wparse 数据面 =="
  if [[ ! -f "${WPARSE_PIDFILE}" ]]; then
    echo "  未在运行。"
    return 0
  fi
  local pid cmd
  pid="$(cat "${WPARSE_PIDFILE}")"
  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    echo "  pidfile 内容不是 pid（${pid}），删掉：${WPARSE_PIDFILE}" >&2
    rm -f "${WPARSE_PIDFILE}"
    return 0
  fi
  # pidfile 可能被别的进程写过（典型：容器把 pid=1 写进共享 work root），盲 kill 会误杀服务。
  cmd="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
  if [[ -z "${cmd}" ]]; then
    echo "  未在运行（stale pidfile pid=${pid}）。"
    rm -f "${WPARSE_PIDFILE}"
    return 0
  fi
  if [[ "${cmd}" != *wparse* ]]; then
    echo "  pidfile 里的 pid=${pid} 不是 wparse，拒绝 kill：$(printf '%.60s' "${cmd}")" >&2
    rm -f "${WPARSE_PIDFILE}"
    return 0
  fi
  kill "${pid}"
  rm -f "${WPARSE_PIDFILE}"
  echo "  已停 (pid=${pid})。"
}

# ────────────────────────────────────────────────────────────────────────────
# web 前端（vite dev server，后台常驻）
# ────────────────────────────────────────────────────────────────────────────
web_up() { curl -s -o /dev/null "${WEB_URL%/}/"; }

web_host() { python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').hostname or '127.0.0.1')"; }
web_port() { python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').port or 80)"; }

# /api 反代目标：给了 WARP_INSIGHT_WEB_PROXY_TARGET 就听；否则从网关配置的 [server] listen_addr 推
# （主机固定 127.0.0.1 —— 配置里写的是 0.0.0.0，那不是能连的地址）。读不到配置才回落 localhost:3000。
web_proxy_target() {
  python3 - "${GW_HOME}/wist-gateway.toml" <<'PY'
import re, sys
try:
    text = open(sys.argv[1]).read()
except OSError:
    print("https://localhost:3000")
    raise SystemExit
section = ""
for line in text.splitlines():
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped
        continue
    if section == "[server]" and re.match(r"^listen_addr\s*=", line):
        match = re.search(r'"([^"]+)"', line)
        if match and ":" in match.group(1):
            print("https://127.0.0.1:" + match.group(1).rsplit(":", 1)[1])
            raise SystemExit
        break
print("https://localhost:3000")
PY
}

start_web() {
  echo "== 前端 web（${WEB_URL}）=="
  if web_up; then
    echo "  已在运行，跳过。"
    return 0
  fi
  require_cmd npm
  [[ -d "${WEB_DIR}" ]] || die "wist-gateway-web 目录不存在：${WEB_DIR}"
  [[ -d "${WEB_DIR}/node_modules" ]] || die "前端依赖缺失：${WEB_DIR}/node_modules（先 cd 过去 npm install）"

  local host port
  host="$(web_host)"
  port="$(web_port)"
  export WARP_INSIGHT_WEB_PROXY_TARGET="${WARP_INSIGHT_WEB_PROXY_TARGET:-$(web_proxy_target)}"

  # 子 shell + exec：$! 即 npm 的 pid。
  (
    cd "${WEB_DIR}"
    exec nohup npm run dev -- --host "${host}" --port "${port}" --strictPort >"${WEB_LOG}" 2>&1
  ) &
  echo $! >"${WEB_PIDFILE}"

  local i
  for i in {1..100}; do
    if web_up; then
      echo "  已启动 (pid=$(cat "${WEB_PIDFILE}"))；/api → ${WARP_INSIGHT_WEB_PROXY_TARGET}"
      return 0
    fi
    sleep 0.2
  done
  echo "  前端未就绪（日志 ${WEB_LOG}）" >&2
  return 1
}

stop_web() {
  echo "== 前端 web（${WEB_URL}）=="
  require_cmd lsof
  if [[ -f "${WEB_PIDFILE}" ]]; then
    local pid
    pid="$(cat "${WEB_PIDFILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      echo "  已停 (pid=${pid})。"
    else
      echo "  未在运行（stale pidfile pid=${pid}）。"
    fi
    rm -f "${WEB_PIDFILE}"
  else
    echo "  未在运行（无 pidfile）。"
  fi
  # 端口兜底：npm 会再 fork 出 vite，只 kill npm 可能把 vite 留成孤儿继续占端口。
  local port leftover
  port="$(web_port)"
  leftover="$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "${leftover}" ]]; then
    echo "  清理 ${port} 端口残留进程：${leftover}"
    kill ${leftover} 2>/dev/null || true
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# 控制面 gateway（前台；写 pidfile 供 stop 精确停止）
# ────────────────────────────────────────────────────────────────────────────
GATEWAY_PID=""

gateway_cleanup() {
  if [[ -n "${GATEWAY_PID}" ]] && kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    kill "${GATEWAY_PID}" 2>/dev/null || true
    wait "${GATEWAY_PID}" 2>/dev/null || true
  fi
  rm -f "${GATEWAY_PIDFILE}"
}

build_binaries() {
  echo "== 构建 Rust 二进制（wist-gateway / wist-agentd）=="
  if [[ "${NO_BUILD}" == "1" ]]; then
    echo "  已跳过（--no-build / SKIP_BUILD=1）"
  else
    require_cmd cargo
    # 不重定向输出：编译错误必须让操作者看见。
    cargo build --manifest-path "${GW_CRATE}/Cargo.toml"
    cargo build --manifest-path "${AGENTD_CRATE}/Cargo.toml"
  fi
  local bin
  for bin in "${GW_CRATE}/target/debug/wist-gateway" "${AGENTD_CRATE}/target/debug/wist-agentd"; do
    [[ -x "${bin}" ]] || die "缺少可执行文件：${bin}（去掉 --no-build 重跑以构建）"
  done
}

# 生成/迁移网关配置。每次启动都做：
#   - 缺配置 → `wist-gateway init-config` 生成（含随机 admin token）；
#   - 信任锚写 `[agent] trust_bundle_file`（优先 gateway-ca.crt.pem，退回叶证书）；迁移旧的内联
#     `trust_bundle = """…"""` 写法（新配置不认它，留着会以 missing field 起不来）；
#   - `package_file` 指到本仓 agentd 二进制（网关启动校验它存在）。
ensure_gateway_config() {
  local config="${GW_HOME}/wist-gateway.toml"
  mkdir -p "${GW_HOME}/state"
  if [[ ! -f "${config}" ]]; then
    echo "  生成网关配置：${config}"
    "${GW_CRATE}/target/debug/wist-gateway" init-config "${config}"
  else
    echo "  复用已有配置：${config}"
  fi

  # ① 信任锚走文件（[agent] trust_bundle_file）。旧名 dev-ca.* → 统一为 gateway-ca.*
  #    （内容不变，锚不变；与发布态同名，便于直接对拷）。
  if [[ -f "${GW_HOME}/state/dev-ca.crt.pem" && ! -f "${GW_HOME}/state/gateway-ca.crt.pem" ]]; then
    mv -f "${GW_HOME}/state/dev-ca.crt.pem" "${GW_HOME}/state/gateway-ca.crt.pem"
    [[ -f "${GW_HOME}/state/dev-ca.key.pem" ]] && mv -f "${GW_HOME}/state/dev-ca.key.pem" "${GW_HOME}/state/gateway-ca.key.pem"
  fi
  python3 - "${GW_HOME}/state/admin-tls.crt.pem" "${GW_HOME}/state/gateway-ca.crt.pem" "${config}" <<'PY'
import os, re, sys
leaf, ca, path = sys.argv[1:4]
anchor = ca if os.path.exists(ca) else leaf
anchor_rel = os.path.join("state", os.path.basename(anchor))
with open(path) as handle:
    lines = handle.read().splitlines()
kept, index = [], 0
while index < len(lines):
    line = lines[index]
    if re.match(r"^trust_bundle\s*=", line):
        if '"""' in line and line.count('"""') < 2:
            index += 1
            while index < len(lines) and '"""' not in lines[index]:
                index += 1
        index += 1
        continue
    kept.append(line)
    index += 1
text = "\n".join(kept) + "\n"
setting = f'trust_bundle_file = "{anchor_rel}"'
if re.search(r"(?m)^trust_bundle_file\s*=", text):
    text = re.sub(r"(?m)^trust_bundle_file\s*=.*$", setting, text, count=1)
else:
    text, replaced = re.subn(r"(?m)^(\[agent\]\s*)$", lambda m: m.group(1) + "\n" + setting, text, count=1)
    if replaced != 1:
        sys.exit("配置里找不到 [agent] 段，无法写入 trust_bundle_file")
with open(path, "w") as handle:
    handle.write(text)
print(f"  trust_bundle_file = {anchor_rel}")
PY

  # ② package_file → 本仓 agentd 二进制
  sed -i '' "s|^package_file = .*|package_file = \"${AGENTD_CRATE}/target/debug/wist-agentd\"|" "${config}"

  # ③ 策展内容（模型仓是创作源，拷到配置目录就近引用；找不到模型仓就跳过）
  ensure_content_files
}

ensure_content_files() {
  local src="${WIST_DESIGN_DIR}/jumo/model/content"
  if [[ ! -d "${src}" ]]; then
    echo "  未找到模型仓内容目录，跳过内容装载：${src}"
    return 0
  fi
  local dst="${GW_HOME}/content"
  mkdir -p "${dst}"
  local name
  for name in catalog.toml packs.toml templates.toml; do
    cp -f "${src}/${name}" "${dst}/${name}"
  done
  python3 - "${GW_HOME}/wist-gateway.toml" <<'PY'
import sys
path = sys.argv[1]
with open(path) as handle:
    lines = handle.readlines()
kept, skipping = [], False
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

ensure_admin_tls_cert() {
  local state_dir="${GW_HOME}/state"
  local cert="${state_dir}/admin-tls.crt.pem"
  require_cmd openssl
  if [[ -f "${cert}" ]] && cert_is_end_entity "${cert}"; then
    return 0
  fi
  if [[ -f "${cert}" ]]; then
    echo "  已有 TLS 证书不是合法叶证书（basicConstraints 非 CA:FALSE），重新生成"
  else
    echo "  生成网关自签 TLS 证书（叶证书形态）"
  fi
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${state_dir}/admin-tls.key.pem" -out "${cert}" -days 365 -subj "/CN=localhost" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
}

cert_is_end_entity() {
  openssl x509 -in "$1" -noout -text 2>/dev/null \
    | grep -A1 "Basic Constraints" | grep -q "CA:FALSE"
}

# 网关监听端口：从配置的 [server] listen_addr 读（[ingest] 也有 listen_addr，别读错段）。
gateway_listen_port() {
  python3 - "${GW_HOME}/wist-gateway.toml" <<'PY'
import re, sys
try:
    text = open(sys.argv[1]).read()
except OSError:
    print("3000")
    raise SystemExit
section = ""
for line in text.splitlines():
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped
        continue
    if section == "[server]" and re.match(r"^listen_addr\s*=", line):
        match = re.search(r'"([^"]+)"', line)
        if match and ":" in match.group(1):
            print(match.group(1).rsplit(":", 1)[1])
            raise SystemExit
        break
print("3000")
PY
}

# 起 gateway（前台）。写本进程 pid 到 GATEWAY_PIDFILE，Ctrl+C 触发 trap 一并停掉 gateway。
start_gateway() {
  echo "== 控制面 gateway =="
  local gw_bin="${GW_CRATE}/target/debug/wist-gateway"
  [[ -x "${gw_bin}" ]] || die "缺少 ${gw_bin}（去掉 --no-build 重跑以构建）"
  require_cmd python3
  require_cmd lsof

  ensure_gateway_config
  ensure_admin_tls_cert

  local listen_port
  listen_port="$(gateway_listen_port)"
  echo "  监听端口：${listen_port}"

  trap gateway_cleanup EXIT INT TERM
  echo $$ >"${GATEWAY_PIDFILE}"

  # 清掉端口上**残留的 wist-gateway**（只 kill 确认是网关的进程 —— 端口可能是别人的服务）。
  local stale_pids stale_pid
  stale_pids="$(lsof -nP -ti "tcp:${listen_port}" -sTCP:LISTEN 2>/dev/null || true)"
  for stale_pid in ${stale_pids}; do
    if lsof -p "${stale_pid}" 2>/dev/null | grep -q "wist-gateway"; then
      echo "  清理 ${listen_port} 端口残留的 wist-gateway：${stale_pid}"
      kill "${stale_pid}" 2>/dev/null || true
    else
      echo "  注意：${listen_port} 端口被别的进程占着（pid=${stale_pid}），没动它" >&2
    fi
  done
  [[ -n "${stale_pids}" ]] && sleep 0.5

  WIST_GATEWAY_CONFIG="${GW_HOME}/wist-gateway.toml" \
    "${gw_bin}" >"/tmp/wist-gateway-server.log" 2>&1 &
  GATEWAY_PID=$!
  echo "  已启动 (pid=${GATEWAY_PID})"

  echo
  echo "gateway 跑在前台，Ctrl+C 停止。"
  echo "  监听    ：见配置的 [server] listen_addr"
  echo "  日志    ：/tmp/wist-gateway-server.log"
  echo "  pid     ：${GATEWAY_PIDFILE}"
  while :; do sleep 60; done
}

stop_gateway() {
  echo "== 控制面 gateway =="
  require_cmd lsof
  local stopped=0 wrapper port pids
  if [[ -f "${GATEWAY_PIDFILE}" ]]; then
    wrapper="$(cat "${GATEWAY_PIDFILE}")"
    if kill -0 "${wrapper}" 2>/dev/null; then
      echo "  停止网关承载进程（pid=${wrapper}）"
      kill "${wrapper}" 2>/dev/null || true
      sleep 1
      stopped=1
    else
      echo "  清理 stale pidfile（pid=${wrapper} 已不在）"
    fi
    rm -f "${GATEWAY_PIDFILE}"
  fi
  # 端口兜底（只 kill 确认是 wist-gateway 的进程）；端口默认从配置读，GATEWAY_PORT 可覆盖。
  port="${GATEWAY_PORT:-$(gateway_listen_port)}"
  pids="$(lsof -nP -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null || true)"
  local pid
  for pid in ${pids}; do
    if lsof -p "${pid}" 2>/dev/null | grep -q "wist-gateway"; then
      echo "  停止 ${port} 端口上的 wist-gateway：${pid}"
      kill "${pid}" 2>/dev/null || true
      stopped=1
    fi
  done
  [[ "${stopped}" == "0" ]] && echo "  未在运行。"
  return 0
}

# ────────────────────────────────────────────────────────────────────────────
# status
# ────────────────────────────────────────────────────────────────────────────
cmd_status() {
  echo "开发态组件状态（组件顺序 = 启动顺序）："
  if vm_up; then printf '  %-8s up   %s\n' "vm" "${VM_URL}"; else printf '  %-8s down\n' "vm"; fi
  if wparse_up; then printf '  %-8s up   pid=%s\n' "wparse" "$(cat "${WPARSE_PIDFILE}")"; else printf '  %-8s down\n' "wparse"; fi
  if web_up; then printf '  %-8s up   %s\n' "web" "${WEB_URL}"; else printf '  %-8s down\n' "web"; fi
  local gw_port gw_state
  gw_port="$(gateway_listen_port)"
  if [[ -f "${GATEWAY_PIDFILE}" ]] && kill -0 "$(cat "${GATEWAY_PIDFILE}")" 2>/dev/null; then
    if lsof -nP -ti "tcp:${gw_port}" -sTCP:LISTEN >/dev/null 2>&1; then
      gw_state="up (pid=$(cat "${GATEWAY_PIDFILE}"), 端口 ${gw_port})"
    else
      gw_state="承载进程在 (pid=$(cat "${GATEWAY_PIDFILE}"))，但端口 ${gw_port} 未监听"
    fi
  elif lsof -nP -ti "tcp:${gw_port}" -sTCP:LISTEN >/dev/null 2>&1; then
    gw_state="up (端口 ${gw_port}, 非本脚本托管)"
  else
    gw_state="down"
  fi
  printf '  %-8s %s\n' "gateway" "${gw_state}"
}

# ────────────────────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────────────────────
cmd="${1:-}"
[[ $# -gt 0 ]] && shift
[[ -n "${cmd}" ]] || { usage >&2; exit 2; }

NO_BUILD=0
DRY_RUN=0
requested=()
for arg in "$@"; do
  case "${arg}" in
    --no-build) NO_BUILD=1 ;;
    --dry-run) DRY_RUN=1 ;;
    vm | wparse | web | gateway | all) requested+=("${arg}") ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "未知参数：${arg}" ;;
  esac
done
[[ "${SKIP_BUILD:-0}" == "1" ]] && NO_BUILD=1

# 组件按固定顺序收集（不给 = 全部；顺带达成 canonical 顺序）。
selected=()
if [[ ${#requested[@]} -eq 0 ]]; then
  selected=(vm wparse web gateway)
else
  for c in vm wparse web gateway; do
    for r in "${requested[@]}"; do
      if [[ "${r}" == "all" || "${r}" == "${c}" ]]; then
        selected+=("${c}")
        break
      fi
    done
  done
fi
[[ ${#selected[@]} -gt 0 ]] || die "没有选中任何组件"

case "${cmd}" in
  start)
    require_cmd curl
    echo "启动开发态组件：${selected[*]}"
    [[ "${DRY_RUN}" == "1" ]] && echo "  [dry-run] 只打印计划，不实际启动"
    echo
    # 先构建一次（失败即中止，不留半栈）；再按序起。
    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "  将要构建：cargo build（wist-gateway / wist-agentd）"
    else
      build_binaries
    fi
    echo
    for c in "${selected[@]}"; do
      if [[ "${DRY_RUN}" == "1" ]]; then
        echo "  将要启动：${c}"
        continue
      fi
      case "${c}" in
        vm) start_vm ;;
        wparse) start_wparse ;;
        web) start_web ;;
        gateway) start_gateway ;; # 前台，阻塞到最后
      esac
      echo
    done
    if [[ "${DRY_RUN}" != "1" && " ${selected[*]} " != *" gateway "* ]]; then
      echo "完成。停止：./dev/svc.sh stop ${selected[*]}"
    fi
    ;;
  stop)
    echo "停止开发态组件（逆序）：$(
      printf '%s ' "${selected[@]}" | awk '{for (i=NF; i>0; i--) printf "%s%s", $i, (i>1?" ":"\n")}'
    )"
    echo
    for i in $(seq $((${#selected[@]} - 1)) -1 0); do
      case "${selected[$i]}" in
        vm) stop_vm ;;
        wparse) stop_wparse ;;
        web) stop_web ;;
        gateway) stop_gateway ;;
      esac
      echo
    done
    ;;
  status)
    cmd_status
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    die "未知子命令：${cmd}（可用：start | stop | status）"
    ;;
esac
