#!/usr/bin/env bash
# 冒烟：把指定服务真的**起一下**，看挂载 / OCI 这一层能不能过。
#
# 为什么需要（而不是靠 `docker compose config`）：
#   `docker compose create` **不会**接触真实挂载，退出 0；只有 `up` 在 runc 创建容器时才失败。
#   实测（2026-11-14）：`create` → 0；`up` → `error mounting ... read-only file system`。
#   静态判据见 `dev/check-compose-mounts.sh`（更快）；本脚本补的是“镜像 / entrypoint /
#   挂载在真实容器里到底行不行”。
#
# 语义边界：**只断言“没在挂载/OCI 阶段炸”**，不断言服务健康（网关要 CA、采集器要凭据，
# 这些在冒烟环境里未必齐）。因此起不来的服务只要能明确区分“mount 失败”与“业务自己退出”，
# 就按各自语义报告。
#
# 用法：
#   dev/smoke-up.sh --yes harvest harvest-bootstrap     # 起这几个，看 6 秒，再删掉
#   dev/smoke-up.sh --yes --keep gateway                # 保留容器（自己 docker logs）
#   dev/smoke-up.sh --yes --compose /tmp/x/c.yml --project-dir /tmp/x t   # 用固定件验证脚本本身
#
# ⚠ 会 `up -d` 并重建这些容器 —— **不要在正在服务的现场栈上跑**。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

YES=0
KEEP=0
WAIT=6
COMPOSE_FILE="sys/docker-compose.yml"
PROJECT_DIR="."
SERVICES=()

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --keep) KEEP=1 ;;
    --wait)
      shift
      WAIT="${1:-}"
      ;;
    --compose)
      shift
      COMPOSE_FILE="${1:-}"
      ;;
    --project-dir)
      shift
      PROJECT_DIR="${1:-}"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "未知参数：$1" >&2
      exit 2
      ;;
    *) SERVICES+=("$1") ;;
  esac
  shift
done

command -v docker >/dev/null 2>&1 || {
  echo "SKIP：没有 docker" >&2
  exit 0
}
[ "${#SERVICES[@]}" -gt 0 ] || {
  echo "错误：至少要给一个服务名（逗号分隔或空格分隔都行）" >&2
  echo "  可选：$(sed -nE 's/^  ([a-z0-9_-]+):$/\1/p' sys/docker-compose.yml | tr '\n' ' ')" >&2
  exit 2
}
[ -f .env ] || {
  echo "错误：缺少 .env —— compose 里的 \${VAR} 展开不了，冒烟等于没做。" >&2
  echo "  先跑：gops sys localize --no-flow --only --no-perms-check" >&2
  exit 2
}
if [ "${YES}" -eq 0 ]; then
  echo "这会 \`docker compose up -d --no-deps\` 并重建：${SERVICES[*]}" >&2
  echo "确认在本地/测试栈上，再带 --yes 重跑。" >&2
  exit 2
fi

COMPOSE=(docker compose --project-directory "${PROJECT_DIR}" -f "${COMPOSE_FILE}")
fail=0

echo "== 起容器：${SERVICES[*]}（等 ${WAIT}s 再看状态）"
if ! "${COMPOSE[@]}" up -d --no-deps "${SERVICES[@]}" 2>&1 | sed 's/^/  /'; then
  echo "  [FAIL] up 本身失败（挂载 / 镜像 / OCI 阶段）" >&2
  fail=1
fi

sleep "${WAIT}"

for svc in "${SERVICES[@]}"; do
  # `-a`：一次性服务（如 harvest-bootstrap）跑完就 exited，不带 -a 会漏掉它 → 误报“没建成”。
  ids=$("${COMPOSE[@]}" ps -aq "${svc}" 2>/dev/null || true)
  if [ -z "${ids}" ]; then
    echo "  [FAIL] ${svc}：没有容器（up 没建成）" >&2
    fail=1
    continue
  fi
  for id in ${ids}; do
    state=$(docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}|{{.State.Error}}' "${id}" 2>/dev/null || echo 'missing|0|')
    status=${state%%|*}
    rest=${state#*|}
    code=${rest%%|*}
    err=${rest#*|}
    logs=$(docker logs --tail 40 "${id}" 2>&1 || true)

    if [ -n "${err}" ]; then
      echo "  [FAIL] ${svc}：容器错误 —— ${err}" >&2
      fail=1
      continue
    fi
    case "${status}" in
      created | dead | restarting)
        echo "  [FAIL] ${svc}：状态 ${status}（起不来）" >&2
        printf '%s\n' "${logs}" | tail -5 | sed 's/^/         /' >&2
        fail=1
        ;;
      exited)
        if [ "${code}" = "0" ]; then
          echo "  [ok]   ${svc}：exited 0（一次性服务正常结束，挂载 / OCI 都过了）"
        else
          echo "  [FAIL] ${svc}：exited ${code}（不是挂载问题，但服务自己退了）" >&2
          printf '%s\n' "${logs}" | tail -5 | sed 's/^/         /' >&2
          fail=1
        fi
        ;;
      *)
        echo "  [ok]   ${svc}：${status}（没有挂载 / OCI 错误）"
        ;;
    esac
  done
done

if [ "${KEEP}" -eq 0 ]; then
  echo "== 清理：rm -sf ${SERVICES[*]}"
  "${COMPOSE[@]}" rm -sf "${SERVICES[@]}" >/dev/null 2>&1 || true
else
  echo "== 保留容器（--keep）：自己看 docker logs"
fi

if [ "${fail}" -ne 0 ]; then
  echo "冒烟失败" >&2
  exit 1
fi
echo "冒烟通过（只证明挂载 / OCI 能过，不代表服务健康）"
