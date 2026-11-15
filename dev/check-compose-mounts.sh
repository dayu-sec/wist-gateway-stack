#!/usr/bin/env bash
# 只读校验「嵌套挂载的挂载点在宿主上真的能建起来」。
#
# 背景（2026-11-14 真实事故）：harvest 的信任锚被挂到 `/etc/wist-harvest/gateway-ca.pem`，
# 而 `/etc/wist-harvest` 本身是配置目录的 `:ro` 挂载 —— `docker compose config` 干净、
# `dev/tests/*` 47 条全绿、`create` 也退出 0，直到 `up` 才在 runc 里炸：
#   `error mounting ... create mountpoint ... read-only file system`
# 判据与两种发作方式见 `scripts/lib/nested-mounts.sh`。
#
# 用法：
#   dev/check-compose-mounts.sh            # declared 模式（CI / 干净 checkout）
#   dev/check-compose-mounts.sh --strict   # 挂载点必须在宿主上真实存在（localize 末尾用）
#
# 前置：`.env` 已生成（`gops sys localize --no-flow --only --no-perms-check`），
#       否则 compose 里的 `${VAR}` 展开不了、派生出的是空路径（检查等于没做）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE=declared
for arg in "$@"; do
  case "$arg" in
    --strict) MODE=strict ;;
    -h | --help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "未知参数：$arg" >&2
      exit 2
      ;;
  esac
done

# shellcheck source=../scripts/lib/nested-mounts.sh
. "$ROOT/scripts/lib/nested-mounts.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP：没有 docker（本检查要渲染 compose）" >&2
  exit 0
fi
if [ ! -f .env ]; then
  echo "错误：缺少 .env —— compose 里的 \${VAR} 展开不了，派生出来的是空路径（检查等于没做）。" >&2
  echo "  先跑：gops sys localize --no-flow --only --no-perms-check" >&2
  exit 2
fi

RENDERED=$(mktemp "${TMPDIR:-/tmp}/compose-rendered.XXXXXX")
trap 'rm -f "${RENDERED}"' EXIT INT TERM

if ! docker compose --project-directory . -f sys/docker-compose.yml config >"${RENDERED}" 2>"${RENDERED}.err"; then
  echo "错误：compose 渲染失败（先看下面的原样输出）：" >&2
  sed 's/^/  /' "${RENDERED}.err" | tail -20 >&2
  rm -f "${RENDERED}.err"
  exit 2
fi
rm -f "${RENDERED}.err"

problems=$(nested_mount_problems "$ROOT" "$MODE" "$RENDERED")
if [ -z "$problems" ]; then
  echo "嵌套挂载检查通过（模式：${MODE}）"
  exit 0
fi

echo "嵌套挂载检查失败（模式：${MODE}）：" >&2
while IFS='|' read -r svc target host reason; do
  printf '  [FAIL] %-18s %s\n         容器内：%s\n         宿主路径：%s\n' \
    "$svc" "$reason" "$target" "$host" >&2
done <<<"$problems"
cat >&2 <<'FIX'
  修法（二选一）：
    1) 把子挂载挂到父挂载之外（推荐：配置目录里的路径会被 localize 重写，别往里塞挂载点）；
    2) 在 localize 阶段以**部署账号**预建它（参考 scripts/init-wparse-admin.sh 的
       NESTED_MOUNTS / NESTED_FILES）—— 不能让 Docker 以 root 建。
FIX
exit 1
