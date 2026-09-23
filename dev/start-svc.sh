#!/usr/bin/env bash
# 开发态一站式启动：VictoriaMetrics + wparse 数据面 + 前端 web + 控制面 gateway。
#
# 与发布态的 `gops sys start`（docker compose 起全栈）对应；开发态用本地二进制。
# 也可继续按组件单独起（start-vm.sh / start-wparse.sh / start-web.sh / start-gateway.sh）。
#
# 行为：
#   0) 构建 Rust 二进制（wist-gateway / wist-agentd）—— 编译失败即中止；SKIP_BUILD=1 跳过
#   1) VictoriaMetrics（http://127.0.0.1:18429）—— 走 Docker，后台常驻；已在跑则跳过
#   2) wparse 数据面 —— 仓内本地二进制（dev/bin/wparse），工程在 ../data-plane；后台常驻，已在跑则跳过
#   3) 前端 web（http://127.0.0.1:5174）—— 后台常驻；已在跑则跳过
#   4) 控制面 gateway（https://127.0.0.1:3000）—— exec 交接给 ./dev/start-gateway.sh，
#      跑在前台：日志直接可见，Ctrl+C 即停 gateway。前三步的常驻进程不受影响，
#      它们与 gateway 一起停用 ./dev/stop-svc.sh。
#
# 用法：
#   ./dev/start-svc.sh              # 全部拉起
#   ./dev/start-svc.sh --dry-run    # 只打印将要做什么（含当前各组件状态），不启动
#
# 可覆盖 env：
#   SKIP_VM=1        不起 VictoriaMetrics（例如确实不需要指标）
#   SKIP_WPARSE=1    不起数据面
#   SKIP_WEB=1       不起前端（只要 gateway）
#   SKIP_BUILD=1     跳过 cargo build（默认每次都构建，见下）
#   WIST_GATEWAY_HOME / WEB_URL / WEB_URL / WEB_DIR   透传给对应子脚本
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKIP_VM="${SKIP_VM:-0}"
SKIP_WPARSE="${SKIP_WPARSE:-0}"
SKIP_WEB="${SKIP_WEB:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
VM_URL="${VM_URL:-http://127.0.0.1:18429}"
WEB_URL="${WEB_URL:-http://127.0.0.1:5174}"
WPARSE_PIDFILE="${WPARSE_PIDFILE:-${STACK_ROOT}/data-plane/data/logs/wparse.pid}"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

note() { echo "  $*"; }

vm_up() { curl -s -o /dev/null "${VM_URL%/}/health"; }

wparse_up() {
  [[ -f "${WPARSE_PIDFILE}" ]] || return 1
  kill -0 "$(cat "${WPARSE_PIDFILE}")" 2>/dev/null
}

web_up() { curl -s -o /dev/null "${WEB_URL%/}/"; }

wait_vm() {
  echo "等待 VictoriaMetrics 就绪..."
  for _ in {1..50}; do
    if vm_up; then
      echo "  VictoriaMetrics 就绪"
      return 0
    fi
    sleep 0.2
  done
  echo "  VictoriaMetrics 未就绪（日志：docker compose logs victoria-metrics）" >&2
  return 1
}

echo "启动开发态全栈（VictoriaMetrics + wparse + web + gateway）"
[[ "${DRY_RUN}" == "1" ]] && echo "  [dry-run] 只打印计划，不实际启动"
echo

# ── 0. 前置检查与构建 ──
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}
require_cmd curl

# 先构建再起组件：编译失败就中止，不留下「VM/wparse/web 已经起了、gateway 却没起」的半栈。
# start-gateway.sh 自己也会构建（直接调用它时用）；这里提前做只为失败快，
# cargo 增量编译在无改动时几乎瞬时，重复调用代价可忽略。
if [[ "${SKIP_BUILD}" == "1" ]]; then
  note "跳过构建（SKIP_BUILD=1）"
elif [[ "${DRY_RUN}" == "1" ]]; then
  note "将要构建：cargo build（wist-gateway / wist-agentd）"
else
  require_cmd cargo
  ROOT_DIR="$(cd "${STACK_ROOT}/.." && pwd)"
  # 不重定向输出：编译错误必须让操作者看见。
  cargo build --manifest-path "${ROOT_DIR}/wist-gateway/Cargo.toml"
  cargo build --manifest-path "${ROOT_DIR}/wist-agentd/Cargo.toml"
  note "已构建 wist-gateway / wist-agentd。"
fi
echo

# ── 1. VictoriaMetrics ──
echo "== 1. VictoriaMetrics（${VM_URL}）=="
if [[ "${SKIP_VM}" == "1" ]]; then
  note "已跳过（SKIP_VM=1）"
elif vm_up; then
  note "已在运行，跳过。"
else
  # 容器后端没起来时 docker 只会抛原始错误，这里先给出可执行的解决办法。
  if ! docker info >/dev/null 2>&1; then
    echo "容器后端未运行，VictoriaMetrics 走 docker compose 起不来。" >&2
    echo "  当前 docker context: $(docker context show 2>/dev/null || echo unknown)" >&2
    echo "  启动后端任选其一：orb start ／ open -a Docker ／ colima start" >&2
    echo "  或明确跳过：SKIP_VM=1 ./dev/start-svc.sh" >&2
    exit 1
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    note "将要启动：./dev/start-vm.sh"
  else
    "${SCRIPT_DIR}/start-vm.sh" >/dev/null
    note "已启动。"
    wait_vm
  fi
fi
echo

# ── 2. wparse 数据面 ──
echo "== 2. wparse 数据面 =="
if [[ "${SKIP_WPARSE}" == "1" ]]; then
  note "已跳过（SKIP_WPARSE=1）"
elif wparse_up; then
  note "已在运行（pid=$(cat "${WPARSE_PIDFILE}")），跳过。"
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    note "将要启动：./dev/start-wparse.sh"
  else
    "${SCRIPT_DIR}/start-wparse.sh" >/dev/null
    note "已启动（pid=$(cat "${WPARSE_PIDFILE}")）。"
  fi
fi
echo

# ── 3. 前端 web ──
echo "== 3. 前端 web（${WEB_URL}）=="
if [[ "${SKIP_WEB}" == "1" ]]; then
  note "已跳过（SKIP_WEB=1）"
elif web_up; then
  note "已在运行，跳过。"
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    note "将要启动：./dev/start-web.sh"
  else
    "${SCRIPT_DIR}/start-web.sh" >/dev/null
    note "已启动。"
  fi
fi
echo

# ── 4. 控制面 gateway（前台交接）──
echo "== 4. 控制面 gateway =="
if [[ "${DRY_RUN}" == "1" ]]; then
  note "将要启动（前台，Ctrl+C 停）：./dev/start-gateway.sh"
  echo
  echo "dry-run 结束。"
  exit 0
fi

cat <<EOF
  说明：
    - gateway 跑在前台，日志直接可见，Ctrl+C 即停（交接给 start-gateway.sh）。
    - 前 3 步是后台常驻，不会一起停；整栈停止用：
        ./dev/stop-svc.sh
      单独停：./dev/stop-web.sh ／ ./dev/stop-wparse.sh ／ ./dev/stop-vm.sh
    - 控制面就绪后，如需把本机 agentd 注册进来：./dev/re-enroll.sh
EOF
echo

# 直接 exec 交接：Ctrl+C（SIGINT）行为与单独跑 ./dev/start-gateway.sh 完全一致。
# 因此常驻组件的停止命令必须在交接前打印完，不能指望本脚本退出后再输出。
exec "${SCRIPT_DIR}/start-gateway.sh"
