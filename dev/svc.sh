#!/usr/bin/env bash
# 开发态统一入口：把本地全栈的「起 / 停 / 看」收在一处。
#
# 对应发布态的 `gops run start|stop|status`（docker compose 起全栈）；开发态用本地二进制，
# 网关持久数据在 `<栈根>/dev/configs/gateway`（发布态另用 `<栈根>/configs/gateway`，两套目录互不影响）。
#
# 用法：
#   ./dev/svc.sh start   [组件…] [--no-build] [--no-forward] [--dry-run]
#   ./dev/svc.sh stop    [组件…]
#   ./dev/svc.sh restart [组件…] [--no-build] [--no-forward] [--dry-run]
#                        # 停所选组件（逆序）再起回（正序）—— 「改了配置/代码要生效」用它
#   ./dev/svc.sh status
#   ./dev/svc.sh token    # 打印**开发态**网关的 admin token 与出处（登录/管理 API 用）
#
#   组件（不给 = vm|wparse|web|forward|gateway）：vm | wparse | web | gateway | forward（也可写 all）
#     forward = `FORWARD_LISTEN （默认 443）→ 网关监听端口` 的纯 TCP 转发。它就一件事：把发布态由
#     docker 提供的那一跳（`${GATEWAY_PORT}:3000`）在 dev 态补上，好让 agentd 用**不带端口**的域名走 443。
#     它在**默认 start 里**（agent 能不能连上来是日常问题，不该靠人记得敲第二个命令）；
#     绑 <1024 的端口要 sudo：能免密就用、交互终端上要一次密码、实在要不到就**跳过并告知**
#     （不拖垮整次 start）。不想碰权限/不需要 agent 面就走 `--no-forward`。
#
#   注：gwlinkd（网关**宿主侧**常驻、接入上级控制中心）**不由本脚本管** —— 不构建、不起、不停、不看。
#   它归**系统服务**：装 / 更新 / 看 / 回滚走 `./dev/install-gwlinkd-dev.sh`；断开接入走 `./dev/unlink-center.sh`。
#
# 同一口径（不再有「有的跳过、有的报错」）：
#   start：先 `cargo build` 一次（wist-gateway + wist-agentd；`--no-build` 或 `SKIP_BUILD=1` 跳过）；
#          每个组件**已在运行则跳过**；按 vm → wparse → web → forward → gateway 顺序；
#          各组件**全部后台常驻**（不随本脚本退出/关终端而停）；起完就返回。
#          **start 从不接管/杀已经在跑的进程**（包括 gateway）—— 要重启就用 `restart`（= 停 + 起）。
#   stop ：按 start 的**逆序**停；未在跑的是 no-op。
#   restart：对所选组件**先停（逆序）再起（正序）**；flags 与 start 同口径（默认会 `cargo build` 一次）。
#   status：只读，打印各组件的当前状态。
#
# 例：
#   ./dev/svc.sh start                  # 全栈（日常；含 443 转发）
#   ./dev/svc.sh start --no-forward     # 不要 agent 面 / 不碰 sudo
#   ./dev/svc.sh restart web            # 只重启前端（gateway 已在跑时）
#   ./dev/svc.sh restart gateway --no-build   # 改了网关配置/代码后重启网关
#   ./dev/svc.sh restart                # 全栈重启
#   ./dev/svc.sh stop web gateway
#   ./dev/svc.sh status
#
# 可覆盖 env（与旧的分散脚本同口径）：
#   SKIP_BUILD=1 等价 --no-build；SKIP_FORWARD=1 等价 --no-forward
#   WIST_GATEWAY_HOME（默认 <栈根>/dev/configs/gateway）  GATEWAY_PIDFILE  GATEWAY_PORT（覆盖停网关时的端口；默认读配置）
#   WEB_URL  WEB_DIR  WEB_LOG  WEB_PIDFILE  WARP_INSIGHT_WEB_PROXY_TARGET
#   WPARSE_BIN  WPARSE_SEED  WPARSE_WORK_ROOT  WPARSE_VM_ENDPOINT  WPARSE_GATEWAY_ENDPOINT
#   WIST_KNOWLEDGE_DIR（默认 <wist 仓组>/wist-knowledge；策展内容源）
#   WIST_GATEWAY_LOCK_FILE（网关单实例锁路径；默认 /tmp/wist-gateway.lock ——
#     同一台机器上要有意并行两套时才改它，改了就真的会有两个网关同时在跑）
#   FORWARD_LISTEN / FORWARD_BIND / FORWARD_TARGET_PORT / FORWARD_PIDFILE / FORWARD_LOG
#     （可选的 443→网关端口 转发，见下面 forward 组件）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# 2026-10 目录重组：crate / 前端 / 知识库收拢进 `wist/` 仓组。脚本还在旧栈位置
# （wist-stack/wist-gateway-stack/dev）时上一级是 x-topology，wist 组是其下的 `wist/`；
# 脚本随栈迁到 wist/wist-gateway-stack/dev 后上一级本身就是 wist 组 —— 两种位置都能解析。
if [[ -d "${ROOT_DIR}/wist/wist-gateway" ]]; then
  ROOT_DIR="${ROOT_DIR}/wist"
# 集成区与组件区为同级目录时（如 x-topology/wist-stack 与 x-topology/wist）
elif [[ -d "${ROOT_DIR}/../wist/wist-gateway" ]]; then
  ROOT_DIR="$(cd "${ROOT_DIR}/../wist" && pwd)"
fi
GW_CRATE="${ROOT_DIR}/wist-gateway"
AGENTD_CRATE="${ROOT_DIR}/wist-agentd"
WIST_KNOWLEDGE_DIR="${WIST_KNOWLEDGE_DIR:-${ROOT_DIR}/wist-knowledge}"

# ── 控制面 gateway ──
GW_HOME="${WIST_GATEWAY_HOME:-${STACK_ROOT}/dev/configs/gateway}"
# 站点身份（CA/证书/私钥/信任锚/签名密钥）放**栈根** `identity/`，dev 与发布态共用同一份。
# GW_HOME 下用 `identity` symlink 指过去，于是配置里的相对路径（identity/public|private/...）从 dev home 即可解析。
# 资源（store/logs/content）仍各态一份，留在 GW_HOME 下，不放共享身份。
GW_IDENTITY="${STACK_ROOT}/identity/gateway"
IDENTITY_PUBLIC="${GW_IDENTITY}/public"
IDENTITY_PRIVATE="${GW_IDENTITY}/private"
IDENTITY_LINK="${GW_HOME}/identity"
# 管理 token 走密钥文件（配置里写 `${SEC_ADMIN_TOKEN}`，值放这里；与发布态同一机制）。
GATEWAY_SEC_FILE="${WIST_GATEWAY_SEC_FILE:-${STACK_ROOT}/.wist/sec-value.yml}"
GATEWAY_PIDFILE="${GATEWAY_PIDFILE:-/tmp/wist-gateway.pid}"
# ── 前端 web ──
WEB_URL="${WEB_URL:-http://127.0.0.1:5174}"
WEB_DIR="${WEB_DIR:-${ROOT_DIR}/wist-gateway-web}"
WEB_LOG="${WEB_LOG:-/tmp/wist-gateway-web.log}"
WEB_PIDFILE="${WEB_PIDFILE:-/tmp/wist-gateway-web.pid}"
# ── 数据面 wparse ──
# 只读种子（随包交付、随版本升级）与开发工作根（可写）分开：
#   种子     sys/data-plane          conf/connectors/models/topology（wparse.local.toml 由本脚本生成开发态版本）
#   开发工作根 data-plane-run/dev    data/ 与 .run/ 是运行态（不入 git，也受 sys-prj protect）
WPARSE_SEED="${WPARSE_SEED:-${STACK_ROOT}/sys/data-plane}"
WPARSE_WORK_ROOT="${WPARSE_WORK_ROOT:-${STACK_ROOT}/data-plane-run/dev}"
WPARSE_BIN="${WPARSE_BIN:-${SCRIPT_DIR}/bin/wparse}"
WPARSE_PIDFILE="${WPARSE_WORK_ROOT}/data/logs/wparse.pid"
export WPARSE_VM_ENDPOINT="${WPARSE_VM_ENDPOINT:-http://127.0.0.1:18429}"
export WPARSE_GATEWAY_ENDPOINT="${WPARSE_GATEWAY_ENDPOINT:-http://127.0.0.1:3001}"
# ── gwlinkd（网关**宿主侧**常驻、接入上级控制中心）**不归本脚本管** ──
# 它已从「svc.sh 的组件」移到**系统服务**：装/更新/看/回滚走 `dev/install-gwlinkd-dev.sh`，
# 断开接入走 `dev/unlink-center.sh`（它们自己解析 gwlinkd 的路径与配置）。这里不再持有它的任何变量。
# ── 可选：端口转发（补上发布态由 docker 提供的那一跳）──
FORWARD_LISTEN="${FORWARD_LISTEN:-443}"
FORWARD_BIND="${FORWARD_BIND:-0.0.0.0}"
# 空 = 按网关配置的 [server] listen_addr 推导
FORWARD_TARGET_PORT="${FORWARD_TARGET_PORT:-}"
FORWARD_PIDFILE="${FORWARD_PIDFILE:-/tmp/wist-gateway-forward.pid}"
FORWARD_LOG="${FORWARD_LOG:-/tmp/wist-gateway-forward.log}"
FORWARD_SCRIPT="${SCRIPT_DIR}/forward-443.py"
# ── 观测 VictoriaMetrics（第三方，走 docker compose）──
VM_URL="${VM_URL:-http://127.0.0.1:18429}"
COMPOSE=(docker compose --project-directory "${STACK_ROOT}" -f "${STACK_ROOT}/sys/docker-compose.yml")

usage() {
  # 打印文件头的**注释块**（第 3 行起，到首个非注释行为止）：加/删注释行都不用改行号。
  awk 'NR>=3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

die() {
  echo "错误：$*" >&2
  exit 1
}

# 进程在不在？**不用 `kill -0`**：它对**别人的**进程（典型：root 起的转发器）回 EPERM，
# 于是“在跑”会被误判成“没跑”（2026-09-30 实撞：`svc.sh start forward` 会拿不到 pid、
# 反复去绑 443）。`ps -p` 能看所有用户的进程。
pid_alive() {
  [[ -n "$1" ]] && ps -p "$1" >/dev/null 2>&1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

# 确保 dev home 里指向**栈根共享身份**的 symlink 存在（缺则建）：
#   · `identity` —— 配置里写相对配置目录的 `identity/public|private/...`，靠它落到共享身份；
#   · `wist-gateway-pub.toml` —— 接口层（对外域名/归属）也在共享身份里，用 symlink 让网关的
#     “配置同目录的 pub.toml”默认查找命中它（于是 dev 与发布态共用同一个域名）。
ensure_identity_link() {
  local identity_target pub_target
  identity_target="$(python3 - "${GW_HOME}" "${GW_IDENTITY}" <<'PY'
import os, sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
  )"
  pub_target="$(python3 - "${GW_HOME}" "${GW_IDENTITY}/public/wist-gateway-pub.toml" <<'PY'
import os, sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
  )"
  mkdir -p "${GW_HOME}"
  ensure_symlink "${IDENTITY_LINK}" "${identity_target}" "identity"
  ensure_symlink "${GW_HOME}/wist-gateway-pub.toml" "${pub_target}" "wist-gateway-pub.toml"
}

# 建/修正一个 symlink；若同名位置是普通文件则拒绝（别把现场值静默顶掉）。
ensure_symlink() {
  local link="$1" target="$2" label="$3"
  if [[ -L "${link}" ]]; then
    [[ "$(readlink "${link}")" == "${target}" ]] && return 0
    echo "  修正 ${label} symlink：$(readlink "${link}") → ${target}"
    ln -sfn "${target}" "${link}"
  elif [[ -e "${link}" ]]; then
    die "${link} 已存在且不是 symlink —— 它应指向 ${target}（请先手工处理）"
  else
    ln -s "${target}" "${link}"
    echo "  已建 ${label} symlink：${link} → ${target}"
  fi
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
# wparse 数据面（本地二进制；种子在 ../sys/data-plane，开发运行根在 ../data-plane-run/dev）
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
        "[wparse] 排查：pgrep -fl 'wparse daemon'；gops run status\n"
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

  # 只读种子 → 开发工作根：只补缺失，不覆盖（与发布态 entrypoint 同口径）。
  if [[ -d "${WPARSE_SEED}" ]]; then
    mkdir -p "${WPARSE_WORK_ROOT}/data" "${WPARSE_WORK_ROOT}/.run"
    for d in conf connectors models topology; do
      mkdir -p "${WPARSE_WORK_ROOT}/${d}"
      cp -an "${WPARSE_SEED}/${d}/." "${WPARSE_WORK_ROOT}/${d}/"
    done
  fi

  # 站点本地覆盖层（[admin_api]）：种子那份是**发布态**（容器内 0.0.0.0 + TLS + /data 路径），
  # 宿主进程用不了，所以开发态自己生成一份（回环 + 无 TLS）；已有现场修改不覆盖。
  # 端口用 19091：发布态容器已经把宿主 127.0.0.1:19090 占住了（两者可能同时跑）。
  mkdir -p "${WPARSE_WORK_ROOT}/.run"
  local local_conf="${WPARSE_WORK_ROOT}/wparse.local.toml"
  if [[ ! -f "${local_conf}" ]]; then
    cat >"${local_conf}" <<'EOF'
# 开发态站点本地覆盖层（dev/svc.sh 生成；只补缺失，不覆盖现场修改）。
# 发布态对应文件绑 0.0.0.0:19090 + TLS；宿主进程改成回环 + 明文，端口避开发布态。
[admin_api]
enabled = true
bind = "127.0.0.1:19091"
request_timeout_ms = 15000
max_body_bytes = 4096

[admin_api.tls]
enabled = false
cert_file = ""
key_file = ""

[admin_api.auth]
# 0.34.0 起不再接受 mode（Bearer Token 是唯一鉴权方式）。
# 相对开发工作根；下面缺则生成（0600）。
token_file = ".run/admin_api.token"
EOF
    echo "  已生成开发态本地覆盖层：${local_conf}（管理面 127.0.0.1:19091）"
  fi
  # 引擎要求 token 文件 0600 且属主为运行用户；开发态直接放在 bind 目录里。
  if [[ ! -s "${WPARSE_WORK_ROOT}/.run/admin_api.token" ]]; then
    python3 -c 'import secrets; print(secrets.token_hex(32))' >"${WPARSE_WORK_ROOT}/.run/admin_api.token"
    chmod 600 "${WPARSE_WORK_ROOT}/.run/admin_api.token"
    echo "  已生成开发态 wparse admin token：${WPARSE_WORK_ROOT}/.run/admin_api.token"
  fi

  [[ -f "${WPARSE_WORK_ROOT}/conf/wparse.toml" ]] || die "缺少 wparse 配置：${WPARSE_WORK_ROOT}/conf/wparse.toml（种子：${WPARSE_SEED}）"

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
      die "已有容器挂着这个 work root（${busy}）—— 同一 work root 只能一个引擎；要停容器：gops run stop"
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

  # admin token 一律由使用者在管理页面手填（存浏览器 sessionStorage，请求时作 Bearer 发出）。
  # web / dev server 都不碰 token：不读配置、不读 env 抠 token、不往页面注入，避免
  # 「拿占位符或错 token 发请求 → 401 → 限流」。取 token 用 `./dev/svc.sh token`。

  # 子 shell + exec：$! 即 npm 的 pid。
  (
    cd "${WEB_DIR}"
    exec nohup npm run dev -- --host "${host}" --port "${port}" --strictPort >"${WEB_LOG}" 2>&1
  ) &
  echo $! >"${WEB_PIDFILE}"

  local pid
  pid="$(cat "${WEB_PIDFILE}")"
  # launch-and-forget：web 是 **pull** 组件（只有人开浏览器才用），栈里没有下游依赖它，
  # 所以**不等就绪** —— 就绪与否交给 `./dev/svc.sh status`。只做一个 1s 存活确认，抓
  # 「--strictPort 端口被占 / 依赖缺失」这类秒退；即便未就绪也不影响整栈。
  sleep 1
  if pid_alive "${pid}"; then
    echo "  已启动 (pid=${pid})；/api → ${WARP_INSIGHT_WEB_PROXY_TARGET}"
    echo "  （不等就绪：自查 ./dev/svc.sh status）"
    return 0
  fi
  echo "  前端进程秒退（pid=${pid}）。日志尾部：" >&2
  tail -n 20 "${WEB_LOG}" >&2 || true
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
# 控制面 gateway（后台常驻；写 pidfile 供 stop 精确停止）
# ────────────────────────────────────────────────────────────────────────────

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
#   - 证书/私钥/信任锚/签名密钥的路径指向**共享身份** `identity/public|private`（而不是 dev home 的
#     state/）；信任锚写 `[agent] trust_bundle_file`（优先 gateway-ca.crt.pem，退回叶证书）；
#     迁移旧的内联 `trust_bundle = """…"""` 写法（新配置不认它，留着会以 missing field 起不来）。
# 注：安装包**不再是配置项**（`agent.package_file` 已删）—— 它只有「管理面录入」一个来源，
#     在「安装包」页录本仓 agentd 二进制的路径即可（dev 态直接填宿主路径）。
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
  #    （内容不变，锚不变；与发布态同名，便于直接对拷）。身份已拆到共享目录：
  #    老的 state/dev-ca.*（或新目录里的 dev-ca.*）一并搬进共享身份再改名。
  local old_crt="" old_key="" base
  for base in "${IDENTITY_PUBLIC}" "${IDENTITY_PRIVATE}" "${GW_HOME}/state"; do
    [[ -f "${base}/dev-ca.crt.pem" ]] && old_crt="${base}/dev-ca.crt.pem"
    [[ -f "${base}/dev-ca.key.pem" ]] && old_key="${base}/dev-ca.key.pem"
  done
  if [[ -n "${old_crt}" && ! -f "${IDENTITY_PUBLIC}/gateway-ca.crt.pem" ]]; then
    mv -f "${old_crt}" "${IDENTITY_PUBLIC}/gateway-ca.crt.pem"
    [[ -n "${old_key}" ]] && mv -f "${old_key}" "${IDENTITY_PRIVATE}/gateway-ca.key.pem"
  fi
  python3 - "${IDENTITY_PUBLIC}/admin-tls.crt.pem" "${IDENTITY_PUBLIC}/gateway-ca.crt.pem" "${config}" "${VM_URL}" <<'PY'
import os, re, sys
leaf, ca, path, vm_url = sys.argv[1:5]
# 锚 = 网关 CA 根（跑过 setup-domain.sh / init-gateway 就有），没有才退回叶证书。
anchor = ca if os.path.exists(ca) else leaf
# 身份在共享身份（identity/）：配置里写相对配置目录的路径，经 dev home 的 identity symlink 落到栈根。
anchor_rel = os.path.join("identity", "public", os.path.basename(anchor))
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

# 旧 `[agent]` 键名 → 新名（配置结构重命名；见 wist-gateway CHANGELOG）。只改键名、留值。
for old, new in {
    "agent_ca_cert_file": "ca_cert_file",
    "agent_ca_key_file": "ca_key_file",
    "bootstrap_token_ttl_seconds": "bootstrap_ttl_seconds",
}.items():
    text = re.sub(rf"(?m)^([ \t]*){re.escape(old)}([ \t]*=)", rf"\g<1>{new}\g<2>", text)

# 证书/私钥/信任锚：真身在**共享身份**（栈根 identity/），配置里写相对配置目录的路径
# （经 dev home 的 identity symlink 落地）。store/logs/content 仍留 dev home，不动。
cert_dirs = {
    "gateway-ca.crt.pem": "identity/public",
    "agent-ca.crt.pem": "identity/public",
    "admin-tls.crt.pem": "identity/public",
    "knowledge-signing.pub.pem": "identity/public",
    "gateway-ca.key.pem": "identity/private",
    "agent-ca.key.pem": "identity/private",
    "admin-tls.key.pem": "identity/private",
}

def _to_identity(match):
    name = match.group(2)
    dest = cert_dirs.get(name)
    return match.group(0) if dest is None else f'{match.group(1)}{dest}/{name}"'

text = re.sub(r'(=[ \t]*")state/([^"/]+)"', _to_identity, text)

setting = f'trust_bundle_file = "{anchor_rel}"'
if re.search(r"(?m)^trust_bundle_file\s*=", text):
    text = re.sub(r"(?m)^trust_bundle_file\s*=.*$", setting, text, count=1)
else:
    text, replaced = re.subn(r"(?m)^(\[agent\]\s*)$", lambda m: m.group(1) + "\n" + setting, text, count=1)
    if replaced != 1:
        sys.exit("配置里找不到 [agent] 段，无法写入 trust_bundle_file")

# 开发态：VM 跑在 docker 但**发布**在宿主端口（VICTORIA_METRICS 的 18429）。
# 配置里若是 compose 服务名（victoria-metrics:8428），宿主进程的网关根本解析不到 ——
# 「数据采集」页会直接 502（failed to query pipeline metrics）。这里每次都改写成宿主可达地址，
# 免得「复用已有配置」把错值一直带下去。
vm_setting = f'victoria_metrics_url = "{vm_url}"'
if re.search(r"(?m)^victoria_metrics_url\s*=", text):
    text = re.sub(r"(?m)^victoria_metrics_url\s*=.*$", vm_setting, text, count=1)
else:
    text, replaced = re.subn(r"(?m)^(\[server\]\s*)$", lambda m: m.group(1) + "\n" + vm_setting, text, count=1)
    if replaced != 1:
        sys.exit("配置里找不到 [server] 段，无法写入 victoria_metrics_url")

with open(path, "w") as handle:
    handle.write(text)
print(f"  trust_bundle_file = {anchor_rel}")
print(f"  victoria_metrics_url = {vm_url}")
PY

  # ③ 管理 token：迁到密钥文件（`.wist/sec-value.yml`），配置改写为 `${SEC_ADMIN_TOKEN}`。
  ensure_gateway_secret "${config}"

  # ② 策展内容（wist-knowledge 是创作源，拷到配置目录就近引用；找不到知识库仓就跳过）
  ensure_content_files
}

# 管理 token 的**密钥文件**化：值落 `<栈根>/.wist/sec-value.yml`（键 `admin_token`），
# 配置里只留 `${SEC_ADMIN_TOKEN}`；网关启动时用 `WIST_GATEWAY_SEC_FILE` 指过去解析（见 `secret_dict`）。
ensure_gateway_secret() {
  local config="$1"
  mkdir -p "$(dirname "${GATEWAY_SEC_FILE}")"

  # 现有**字面** token（老配置 / init-config 生成的）优先迁入；否则随机。
  # 确保 `admin_token` 键存在（文件缺则建、键缺则补；已有其它键与已有 token 一律保留）。
  [[ -f "${GATEWAY_SEC_FILE}" ]] || : >"${GATEWAY_SEC_FILE}"
  local literal
  literal="$(sed -n 's/^[[:space:]]*admin_api_token[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${config}" | sed -n '1p')"
  python3 - "${GATEWAY_SEC_FILE}" "${literal}" <<'PY'
import re, secrets, sys
path, literal = sys.argv[1], sys.argv[2]
with open(path) as handle:
    text = handle.read()
if re.search(r"(?m)^\s*admin_token\s*:", text):
    print("  复用已有 admin_token：", path)
    sys.exit(0)
token = literal if literal and literal != "${SEC_ADMIN_TOKEN}" else secrets.token_hex(24)
if text and not text.endswith("\n"):
    text += "\n"
text += f"admin_token: {token}\n"
with open(path, "w") as handle:
    handle.write(text)
print("  已在密钥文件写入 admin_token：", path)
PY
  chmod 600 "${GATEWAY_SEC_FILE}"

  # 配置统一改写为 `${SEC_ADMIN_TOKEN}`（无论原来是字面还是已占位）。
  python3 - "${config}" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as handle:
    text = handle.read()
setting = 'admin_api_token = "${SEC_ADMIN_TOKEN}"'
if re.search(r"(?m)^admin_api_token\s*=", text):
    text = re.sub(r"(?m)^admin_api_token\s*=.*$", setting, text, count=1)
else:
    text, n = re.subn(r"(?m)^(\[server\]\s*)$", lambda m: m.group(1) + "\n" + setting, text, count=1)
    if n != 1:
        sys.exit("配置里找不到 [server] 段，无法写入 admin_api_token")
with open(path, "w") as handle:
    handle.write(text)
print("  admin_api_token = ${SEC_ADMIN_TOKEN}（值在密钥文件）")
PY
}

ensure_content_files() {
  local src="${WIST_KNOWLEDGE_DIR}"
  if [[ ! -d "${src}" ]]; then
    echo "  未找到知识库仓目录，跳过内容装载：${src}"
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
  # 叶证书/私钥落**共享身份**（公开证书进 public，私钥进 private），与 setup-domain.sh 同一份。
  local cert="${IDENTITY_PUBLIC}/admin-tls.crt.pem"
  local key="${IDENTITY_PRIVATE}/admin-tls.key.pem"
  local ca_crt="${IDENTITY_PUBLIC}/gateway-ca.crt.pem"
  local ca_key="${IDENTITY_PRIVATE}/gateway-ca.key.pem"
  mkdir -p "${IDENTITY_PUBLIC}" "${IDENTITY_PRIVATE}"
  require_cmd openssl
  if [[ -f "${cert}" ]] && cert_is_end_entity "${cert}"; then
    return 0
  fi
  if [[ -f "${cert}" ]]; then
    echo "  已有 TLS 证书不是合法叶证书（basicConstraints 非 CA:FALSE），重新生成"
  else
    echo "  生成网关 TLS 叶证书"
  fi
  local ext="${IDENTITY_PRIVATE}/.admin-tls.ext"
  cat >"${ext}" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1,DNS:localhost
EOF
  if [[ -f "${ca_crt}" && -f "${ca_key}" ]]; then
    # 有共享网关 CA 就用它签：锚保持稳定，换库/换域名不换锚（已装 agent 无感）。
    # 私钥是耗材：缺则生成，已有则复用（轮换应是刻意的，不该是脚本的副作用）。
    if [[ ! -f "${key}" ]]; then
      openssl genrsa -out "${key}" 2048 >/dev/null 2>&1
      chmod 600 "${key}"
    fi
    local csr="${IDENTITY_PRIVATE}/.admin-tls.csr.pem"
    openssl req -new -key "${key}" -out "${csr}" -subj "/CN=localhost" >/dev/null 2>&1
    # 序列号文件（.srl）也落私钥目录（不在公开的 CA 证书目录里）。
    openssl x509 -req -in "${csr}" -CA "${ca_crt}" -CAkey "${ca_key}" \
      -CAserial "${IDENTITY_PRIVATE}/gateway-ca.crt.srl" -CAcreateserial \
      -out "${cert}" -days 365 -sha256 -extfile "${ext}" >/dev/null 2>&1
    rm -f "${csr}" "${ext}"
    echo "  已用共享 CA 签出 TLS 叶证书：${cert}"
  else
    # 没有 CA 才自签：此时叶证书同时是信任锚（换域名 = 换锚 = 所有 agent 要重装）。
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${key}" -out "${cert}" -days 365 -subj "/CN=localhost" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=serverAuth" \
      -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
    rm -f "${ext}"
    echo "  已自签 TLS 叶证书：${cert}（无共享 CA）"
  fi
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

# 网关是不是已经在跑了？两种情况都算“在跑”，都**跳过**（不杀）：
#   ① 本脚本托管的那个还在（pidfile 里的 wrapper 活着）；
#   ② 配置的网关端口上有 `wist-gateway` 在听 —— 可能是别处起的（另一个 home / 另一个 svc 入口），
#      也可能是上次没用 svc.sh 停的。
# 端口上若是**别的**程序，直接报错退出：那时候再怎么起网关也只会撞 EADDRINUSE，
# 与其让人看一句晦涩的绑定失败，不如当场说清。
gateway_already_running() {
  local listen_port="$1" pid running_pid
  if [[ -f "${GATEWAY_PIDFILE}" ]]; then
    pid="$(cat "${GATEWAY_PIDFILE}")"
    if pid_alive "${pid}"; then
      echo "  已在运行（本脚本托管，pid=${pid}），跳过。"
      echo "  要重启：./dev/svc.sh stop gateway && ./dev/svc.sh start gateway"
      return 0
    fi
    echo "  清理 stale pidfile（pid=${pid} 已不在）"
    rm -f "${GATEWAY_PIDFILE}"
  fi
  running_pid="$(lsof -nP -ti "tcp:${listen_port}" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  if [[ -n "${running_pid}" ]]; then
    if lsof -p "${running_pid}" 2>/dev/null | grep -q "wist-gateway"; then
      echo "  已有网关在 ${listen_port} 端口上跑（pid=${running_pid}），跳过。"
      echo "  要重启：./dev/svc.sh stop gateway && ./dev/svc.sh start gateway"
      return 0
    fi
    die "端口 ${listen_port} 被别的进程占着（pid=${running_pid}）：改配置里的 [server] listen_addr，或先停掉它"
  fi
  return 1
}

# 起 gateway（**后台常驻**）。写**网关自身**的 pid 到 GATEWAY_PIDFILE；脚本退返、终端关闭都不影响它。
start_gateway() {
  echo "== 控制面 gateway =="
  local gw_bin="${GW_CRATE}/target/debug/wist-gateway"
  [[ -x "${gw_bin}" ]] || die "缺少 ${gw_bin}（去掉 --no-build 重跑以构建）"
  require_cmd python3
  require_cmd lsof

  ensure_identity_link
  ensure_gateway_config
  ensure_admin_tls_cert

  local listen_port
  listen_port="$(gateway_listen_port)"
  echo "  监听端口：${listen_port}"

  # 已经在跑就**跳过**（与 vm / wparse / web 同一口径，README 也是这么写的）——
  # 绝不"把正在跑的那个杀了再顶上"：静默接管一个健康实例，正是"那网关到底跑没跑/停的是哪个"
  # 这类混乱的来源。要重启就显式 stop + start。
  if gateway_already_running "${listen_port}"; then
    return 0
  fi

  # 后台常驻（与 web/wparse 同一口径）：`nohup` 分离，脚本退出/关终端都不影响它。
  # pidfile 记**网关自身**的 pid（不再记承载进程 —— 没有承载进程了）；两处 `exec` 保证 `$!` 就是它。
  (
    export WIST_GATEWAY_CONFIG="${GW_HOME}/wist-gateway.toml"
    export WIST_GATEWAY_SEC_FILE="${GATEWAY_SEC_FILE}"
    # 全栈版本（页面左下角展示）：开发态没有 compose 挂载，直接指向栈根 `version.txt`。
    export WIST_GATEWAY_STACK_VERSION_FILE="${STACK_ROOT}/version.txt"
    exec nohup "${gw_bin}" >"/tmp/wist-gateway-server.log" 2>&1
  ) &
  local pid=$!
  echo "${pid}" >"${GATEWAY_PIDFILE}"

  # 起来之后要**确认它真的在跑**：启动期的拒绝（单实例闸门、库/证书读不开）会立刻退出，
  # 此时把日志尾巴摆出来 —— 否则屏幕上只剩一句“已启动”，人去浏览器里才发现服务不在。
  local i listening=0
  for i in {1..50}; do
    if ! pid_alive "${pid}"; then
      echo "  网关启动失败（进程已退出）。日志尾部：" >&2
      tail -n 5 "/tmp/wist-gateway-server.log" >&2 || true
      rm -f "${GATEWAY_PIDFILE}"
      return 1
    fi
    if lsof -nP -ti "tcp:${listen_port}" -sTCP:LISTEN >/dev/null 2>&1; then
      listening=1
      break
    fi
    sleep 0.2
  done
  if [[ "${listening}" != "1" ]]; then
    echo "  网关进程在，但 ${listen_port} 未监听（可能仍在启动）。日志尾部：" >&2
    tail -n 5 "/tmp/wist-gateway-server.log" >&2 || true
    return 1
  fi

  echo "  已启动 (pid=${pid})"
  echo
  echo "gateway 在后台运行。"
  echo "  监听    ：见配置的 [server] listen_addr"
  echo "  日志    ：/tmp/wist-gateway-server.log"
  echo "  pid     ：${GATEWAY_PIDFILE}"
  echo "  停止    ：./dev/svc.sh stop gateway"
}

stop_gateway() {
  echo "== 控制面 gateway =="
  require_cmd lsof
  local stopped=0 pid_in_file port pids
  if [[ -f "${GATEWAY_PIDFILE}" ]]; then
    pid_in_file="$(cat "${GATEWAY_PIDFILE}")"
    if pid_alive "${pid_in_file}"; then
      echo "  停止网关（pid=${pid_in_file}）"
      kill "${pid_in_file}" 2>/dev/null || true
      sleep 1
      stopped=1
    else
      echo "  清理 stale pidfile（pid=${pid_in_file} 已不在）"
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
  # 转发器**不跟着活**：443 只在网关活着时有意义。网关一退却留着一个“接受连接但连不上后端”的
  # 443，比没有更坑 —— agent 侧看到的是 transport error，看着像证书/信任问题（2026-09-30 实撞）。
  # （以前靠前台网关退出时的 EXIT trap 做到；现在网关后台常驻，就把它放在 stop 里。）
  if [[ -n "$(forward_pid)" ]]; then
    echo
    echo "（网关已停）一并停掉 ${FORWARD_LISTEN} 转发：443 只在网关活着时有意义。"
    stop_forward || true
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# 可选组件：端口转发（`FORWARD_LISTEN` → 127.0.0.1:<网关端口>）
#
# 为什么单独一个组件：发布态 agentd 走的 `443` 是 docker 的端口映射给的；dev 态网关是普通进程、
# 按配置听高位端口。这一跳不补上，agent 就只能拿“域名:3000”去连 —— 那就不是发布态那个形态了。
# 不并进默认 `start`：绑 <1024 的端口要 sudo，不能让人每次起全栈都碰权限。
# ────────────────────────────────────────────────────────────────────────────

# 转发目标端口：显式给了就用，否则取网关配置里的 `[server] listen_addr`。
forward_target_port() {
  if [[ -n "${FORWARD_TARGET_PORT}" ]]; then
    echo "${FORWARD_TARGET_PORT}"
  else
    gateway_listen_port
  fi
}

# 转发器的 pid（pidfile 里的进程还在才算；它一般是 root 起的，所以用 `pid_alive` 而不是 `kill -0`）。
forward_pid() {
  [[ -f "${FORWARD_PIDFILE}" ]] || return 0
  local pid
  pid="$(cat "${FORWARD_PIDFILE}")"
  if pid_alive "${pid}"; then
    echo "${pid}"
  fi
}

start_forward() {
  # $1 = 1 表示“用户点名要它”（此时要不到 sudo 是错误）；默认路径传 0（跳过并告知）。
  local explicit="${1:-0}" target
  target="$(forward_target_port)"
  echo "== 端口转发（${FORWARD_BIND}:${FORWARD_LISTEN} → 127.0.0.1:${target}）=="
  if [[ "${FORWARD_LISTEN}" == "${target}" ]]; then
    echo "  网关本来就在 ${target} 上听，不需要转发，跳过。"
    return 0
  fi
  [[ -f "${FORWARD_SCRIPT}" ]] || die "缺少转发脚本：${FORWARD_SCRIPT}"
  require_cmd python3
  require_cmd lsof

  local pid holder sudo_cmd=""
  pid="$(forward_pid)"
  if [[ -n "${pid}" ]]; then
    echo "  已在运行 (pid=${pid})，跳过。"
    return 0
  fi
  # 残留 pidfile（进程已不在）清掉，否则它会一直装成“在托管”。
  rm -f "${FORWARD_PIDFILE}" 2>/dev/null || true

  holder="$(lsof -nP -ti "tcp:${FORWARD_LISTEN}" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  if [[ -n "${holder}" ]]; then
    die "${FORWARD_LISTEN} 端口已被 pid=${holder} 占着：先停掉它（或改 FORWARD_LISTEN 指到别的端口）"
  fi

  # 绑 <1024 的端口要 root。三级降级：免密 sudo → 交互终端上要一次密码 → 要不到就跳过。
  # “跳过”而不是报错，是为了让默认的 `start` 在无 tty / 没 sudo 的环境里仍然能把栈起起来。
  if ((FORWARD_LISTEN < 1024)) && [[ "$(id -u)" != "0" ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      [[ "${explicit}" == "1" ]] && die "绑定 ${FORWARD_LISTEN} 需要 sudo，而这个环境里没有 sudo"
      echo "  跳过 ${FORWARD_LISTEN} 转发：绑特权端口要 sudo，而这里没有 sudo" >&2
      return 0
    fi
    if sudo -n true 2>/dev/null; then
      sudo_cmd="sudo"
    elif [[ -t 0 ]]; then
      echo "  ${FORWARD_LISTEN} 是特权端口，需要 sudo（网关本身仍以 $(id -un) 跑）"
      if sudo -v; then
        sudo_cmd="sudo"
      elif [[ "${explicit}" == "1" ]]; then
        die "sudo 未通过，转发器没起"
      else
        echo "  跳过 ${FORWARD_LISTEN} 转发（sudo 未通过）；要它就在有终端的会话里重跑" >&2
        return 0
      fi
    elif [[ "${explicit}" == "1" ]]; then
      die "绑定 ${FORWARD_LISTEN} 需要 sudo，而当前不是交互终端"
    else
      echo "  跳过 ${FORWARD_LISTEN} 转发：绑特权端口要 sudo，当前不是交互终端（要它就用 ./dev/svc.sh start forward）" >&2
      return 0
    fi
  fi

  # 起法分两种（`-b` 是 sudo 的选项，不能无条件塞在命令前面）：
  #   root 身份：`sudo -b`（密码已由 sudo -v 拿过）—— sudo 自己 fork 到后台并立刻返回；
  #   用户身份：`( exec nohup … ) &` —— 与 web 同一口径，脚本退出也不影响它。
  local fwd_args=("${FORWARD_LISTEN}" "${target}" --bind "${FORWARD_BIND}" --pidfile "${FORWARD_PIDFILE}")
  if [[ -n "${sudo_cmd}" ]]; then
    # 重定向由**调用者**（部署账号）打开：FORWARD_LOG 默认在 /tmp 下，不需要 root 写权限。
    # shellcheck disable=SC2024
    sudo -b python3 "${FORWARD_SCRIPT}" "${fwd_args[@]}" >"${FORWARD_LOG}" 2>&1
  else
    (
      exec nohup python3 "${FORWARD_SCRIPT}" "${fwd_args[@]}" >"${FORWARD_LOG}" 2>&1
    ) &
  fi

  local i
  # 就绪判据用**进程存活**（pidfile + `ps`），**不用 lsof 看 443 监听**：转发器是 root 起的，
  # 非 root 的 lsof 看不见别人的监听 socket（stop_forward 早有同款注释），拿它当判据会**永远误报未就绪**。
  # 另：此刻网关往往还没起（forward 排在 gateway 前），后端不可达是正常的，不该算失败。
  for i in {1..50}; do
    if pid_alive "$(forward_pid)"; then
      echo "  已启动 (pid=$(forward_pid))；agent 侧仍用 https://<域名>（不带端口）"
      echo "  注：网关看到的对端地址会变成 127.0.0.1（要保真实源 IP 得改用 pf rdr）"
      return 0
    fi
    sleep 0.2
  done
  echo "  转发器进程未起（日志 ${FORWARD_LOG}）：" >&2
  tail -n 5 "${FORWARD_LOG}" >&2 || true
  return 1
}

stop_forward() {
  echo "== 端口转发（${FORWARD_LISTEN}）=="
  require_cmd lsof
  local pid holder
  pid="$(forward_pid)"
  if [[ -z "${pid}" ]]; then
    # pidfile 丢了也兜一下：端口上跑的确实是我们的转发脚本就收掉。
    holder="$(lsof -nP -ti "tcp:${FORWARD_LISTEN}" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
    if [[ -n "${holder}" ]] && ps -o command= -p "${holder}" 2>/dev/null | grep -q "forward-443.py"; then
      pid="${holder}"
    fi
  fi
  rm -f "${FORWARD_PIDFILE}" 2>/dev/null || true
  if [[ -z "${pid}" ]]; then
    echo "  未在运行。"
    return 0
  fi
  # 转发器通常是 root 起的：普通用户 kill 会 EPERM，退回 sudo。
  if kill "${pid}" 2>/dev/null; then
    echo "  已停 (pid=${pid})。"
  elif command -v sudo >/dev/null 2>&1 && sudo kill "${pid}" 2>/dev/null; then
    echo "  已停 (pid=${pid}，sudo)。"
  else
    # 停不掉就**只报错、不动 pidfile**：在非 root 下它是“谁在跑”的唯一线索
    # （lsof 看不见别人的监听 socket）。删了就真找不回来了。
    echo "  停止失败（pid=${pid} 可能是 root 起的）：请手动 sudo kill ${pid}" >&2
    return 1
  fi
  rm -f "${FORWARD_PIDFILE}" 2>/dev/null || true
  sleep 0.3
}

# ────────────────────────────────────────────────────────────────────────────
# status
# ────────────────────────────────────────────────────────────────────────────
cmd_status() {
  echo "开发态组件状态（组件顺序 = 启动顺序）："
  if vm_up; then printf '  %-8s up   %s\n' "vm" "${VM_URL}"; else printf '  %-8s down\n' "vm"; fi
  if wparse_up; then printf '  %-8s up   pid=%s\n' "wparse" "$(cat "${WPARSE_PIDFILE}")"; else printf '  %-8s down\n' "wparse"; fi
  if web_up; then printf '  %-8s up   %s\n' "web" "${WEB_URL}"; else printf '  %-8s down\n' "web"; fi
  local gw_port gw_state gw_listening=0
  gw_port="$(gateway_listen_port)"
  if lsof -nP -ti "tcp:${gw_port}" -sTCP:LISTEN >/dev/null 2>&1; then
    gw_listening=1
  fi
  if [[ -f "${GATEWAY_PIDFILE}" ]] && pid_alive "$(cat "${GATEWAY_PIDFILE}")"; then
    if [[ "${gw_listening}" == "1" ]]; then
      gw_state="up (pid=$(cat "${GATEWAY_PIDFILE}"), 端口 ${gw_port})"
    else
      gw_state="进程在 (pid=$(cat "${GATEWAY_PIDFILE}"))，但端口 ${gw_port} 未监听"
    fi
  elif [[ "${gw_listening}" == "1" ]]; then
    gw_state="up (端口 ${gw_port}, 非本脚本托管)"
  else
    gw_state="down"
  fi
  printf '  %-8s %s\n' "gateway" "${gw_state}"

  # 端口转发：不逼着你起，但要一眼看得出“agent 能不能真的连到网关”。
  local fwd_target fwd_state fwd_pid fwd_holder fwd_listening=0
  fwd_target="$(forward_target_port)"
  if [[ "${FORWARD_LISTEN}" == "${fwd_target}" ]]; then
    fwd_state="n/a  （网关自己就在 ${FORWARD_LISTEN} 上听）"
    fwd_listening=1
  else
    # 认定“在听”优先看**pidfile**：转发器通常是 root 起的，而 lsof 在非 root 下**看不见**
    # 别的用户的监听 socket（会把它误判成 down）。lsof 只做兵底，用来对付非本脚本托管的监听者。
    fwd_pid="$(forward_pid)"
    fwd_holder=""
    if [[ -z "${fwd_pid}" ]] && lsof -nP -ti "tcp:${FORWARD_LISTEN}" -sTCP:LISTEN >/dev/null 2>&1; then
      fwd_holder="$(lsof -nP -ti "tcp:${FORWARD_LISTEN}" -sTCP:LISTEN 2>/dev/null | head -1)"
    fi
    if [[ -n "${fwd_pid}" || -n "${fwd_holder}" ]]; then
      fwd_listening=1
      fwd_state="up   ${FORWARD_LISTEN} → 127.0.0.1:${fwd_target}"
      if [[ -n "${fwd_pid}" ]]; then
        fwd_state="${fwd_state} (pid=${fwd_pid})"
      else
        fwd_state="${fwd_state} (pid=${fwd_holder}，非本脚本托管)"
      fi
    else
      fwd_state="down （agent 走 ${FORWARD_LISTEN} 靠它；默认 start 会带上）"
    fi
  fi
  printf '  %-8s %s\n' "forward" "${fwd_state}"

  # 最坑的组合：443 在听（转发器活着）但后端没在听。agent 侧看到的是 **transport error**
  # （掉线/超时那类），看着像证书或信任锚的问题，而真正的原因就在上一行。直接点出来。
  if [[ "${fwd_listening}" == "1" && "${gw_listening}" != "1" && "${FORWARD_LISTEN}" != "${fwd_target}" ]]; then
    printf '  %-8s %s\n' "⚠" "${FORWARD_LISTEN} 在听但网关没在听：agent 会看到 transport error（不是拒连，别往证书上查）"
  fi

  # 登录/管理 API 的 token 常被翻错地方（仓库里还有一份发布态配置）。这里只指个路。
  printf '  %-8s %s\n' "token" "登录管理员界面用的 token：./dev/svc.sh token"
}

# 打印**开发态**网关的 admin token 与出处。存在的意义：仓库里还有一份长得一样的
# 发布态配置（<栈根>/configs/gateway/wist-gateway.toml，是 .gitignore 的本地渲染生成物），
# 它的 token 是**另一个**；人很容易照错那份去登录。本命令只认开发态 home。
cmd_token() {
  local config="${GW_HOME}/wist-gateway.toml"
  [[ -f "${config}" ]] || die "找不到开发态网关配置：${config}（还没起过网关？先 ./dev/svc.sh start gateway）"
  [[ -f "${GATEWAY_SEC_FILE}" ]] || die "找不到密钥文件：${GATEWAY_SEC_FILE}（先 ./dev/svc.sh start gateway）"
  local token listen base
  token="$(sed -n 's/^[[:space:]]*admin_token:[[:space:]]*//p' "${GATEWAY_SEC_FILE}" | head -1)"
  token="${token%\"}"; token="${token#\"}"; token="${token%\'}"; token="${token#\'}"
  listen="$(sed -n 's/^[[:space:]]*listen_addr[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${config}" | head -1)"
  base="$(sed -n 's/^[[:space:]]*public_base_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${GW_HOME}/wist-gateway-pub.toml" | head -1)"
  [[ -n "${token}" ]] || die "在 ${GATEWAY_SEC_FILE} 里没找到 admin_token"
  cat <<EOF
开发态网关 admin Bearer token（登录「${WEB_URL}」/ 直接打管理 API 都用它）：

  ${token}

  读取自： ${GATEWAY_SEC_FILE}（密钥文件，键 admin_token）
           ← 开发态（本机进程）；网关 home = ${GW_HOME}；配置里只写 \${SEC_ADMIN_TOKEN}
  监听：   ${listen:-?}
  对外基址： ${base:-?}

提示：发布态 token 是另一把（同样在密钥文件里），与上面这份**不同** —— 本机跑的是开发态，用上面这个。
EOF
}

# ────────────────────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────────────────────
cmd="${1:-}"
[[ $# -gt 0 ]] && shift
[[ -n "${cmd}" ]] || { usage >&2; exit 2; }

NO_BUILD=0
DRY_RUN=0
SKIP_FORWARD="${SKIP_FORWARD:-0}"
FORWARD_EXPLICIT=0
requested=()
for arg in "$@"; do
  case "${arg}" in
    --no-build) NO_BUILD=1 ;;
    --no-forward) SKIP_FORWARD=1 ;;
    --dry-run) DRY_RUN=1 ;;
    vm | wparse | web | gateway | forward | all)
      requested+=("${arg}")
      [[ "${arg}" == "forward" ]] && FORWARD_EXPLICIT=1
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "未知参数：${arg}" ;;
  esac
done
[[ "${SKIP_BUILD:-0}" == "1" ]] && NO_BUILD=1

# 组件按固定顺序收集（不给 = 默认全量，**含 forward**；顺带达成 canonical 顺序）。
# gateway 排最后（主服务；它起来时其余依赖已在）。全部后台常驻，顺序只是启动先后。
# `--no-forward` / SKIP_FORWARD=1 把它整个摘掉（不需要 agent 面 / 不想碰 sudo 时用）。
COMPONENTS=(vm wparse web forward gateway)
selected=()
for c in "${COMPONENTS[@]}"; do
  if [[ "${SKIP_FORWARD}" == "1" && "${c}" == "forward" ]]; then
    continue
  fi
  if [[ ${#requested[@]} -eq 0 ]]; then
    selected+=("${c}")
    continue
  fi
  for r in "${requested[@]}"; do
    if [[ "${r}" == "${c}" ]] || [[ "${r}" == "all" ]]; then
      selected+=("${c}")
      break
    fi
  done
done
[[ ${#selected[@]} -gt 0 ]] || die "没有选中任何组件"

# 停所选组件（逆序）。stop 与 restart 共用。
cmd_stop_selected() {
  echo "停止开发态组件（逆序）：$(
    printf '%s ' "${selected[@]}" | awk '{for (i=NF; i>0; i--) printf "%s%s", $i, (i>1?" ":"\n")}'
  )"
  echo
  for i in $(seq $((${#selected[@]} - 1)) -1 0); do
    case "${selected[$i]}" in
      vm) stop_vm ;;
      wparse) stop_wparse ;;
      web) stop_web ;;
      forward) stop_forward ;;
      gateway) stop_gateway ;;
    esac
    echo
  done
}

# 起所选组件（正序）。start 与 restart 共用。
cmd_start_selected() {
  require_cmd curl
  echo "启动开发态组件：${selected[*]}"
  [[ "${DRY_RUN}" == "1" ]] && echo "  [dry-run] 只打印计划，不实际启动"
  echo
  # 先构建一次（**只有构建失败才中止**：没二进制后面无从谈起）；再按序起。
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  将要构建：cargo build（wist-gateway / wist-agentd）"
  else
    build_binaries
  fi
  echo
  # 全部组件后台常驻、彼此独立：任一组件起不来只 WARN、不中止整栈
  # （绑到一起会让一个慢/坏的前端挡住网关，是结构性耦合）。
  failed=()
  for c in "${selected[@]}"; do
    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "  将要启动：${c}"
      continue
    fi
    # 子 shell：组件函数里的 `die`（exit 1）只结束子 shell，不会掀翻整栈。
    if ( case "${c}" in
           vm) start_vm ;;
           wparse) start_wparse ;;
           web) start_web ;;
           forward) start_forward "${FORWARD_EXPLICIT}" ;;
           gateway) start_gateway ;;
         esac ); then
      :
    else
      failed+=("${c}")
      echo "  [warn] ${c} 未就绪/未成功，继续（不影响其它组件）。" >&2
    fi
    echo
  done
  if [[ "${DRY_RUN}" != "1" ]]; then
    if [[ ${#failed[@]} -gt 0 ]]; then
      echo "启动小结：未就绪 = ${failed[*]}；其余已起。复核：./dev/svc.sh status" >&2
      echo
    fi
    echo "完成。全部后台运行。停止：./dev/svc.sh stop ${selected[*]}"
    # 有未就绪组件时以非 0 退，便于脚本/CI 察觉（但整栈已经起来了）。
    [[ ${#failed[@]} -eq 0 ]] || exit 1
  fi
}

case "${cmd}" in
  start)
    cmd_start_selected
    ;;
  stop)
    cmd_stop_selected
    ;;
  restart)
    echo "重启开发态组件（停 → 起）：${selected[*]}"
    echo
    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "  [dry-run] 将停（逆序）：${selected[*]}；再起（正序）：${selected[*]}"
    else
      cmd_stop_selected
      cmd_start_selected
    fi
    ;;
  status)
    cmd_status
    ;;
  token)
    cmd_token
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    die "未知子命令：${cmd}（可用：start | stop | restart | status | token）"
    ;;
esac
