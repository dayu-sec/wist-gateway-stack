#!/usr/bin/env bash
# 只读校验「bind 挂载身份契约」：同一挂载源被两种容器身份挂载、`0600` 配非 root 容器这类
# **配置错误**，在开发 / CI 阶段就拦住 —— 而不是等 Linux 部署时变成 localize 第 ⑥ 步的
# 阻断、再由 `gops prj upgrade` 整栈回滚（2026-11-08 就是这样丢了一次升级）。
#
# 为什么单独包一层而不是直接 `gops sys perms --check`：
#   · `--check` 在 **macOS 上整段跳过**（平台门禁：那边不映射 uid/gid），本地看不见；
#   · 完整 `--check` 还会报“挂载源不存在 / 模式没对齐”。那是**部署事实**，干净的
#     checkout 上必然不满足，拿来当 CI 门槛会让任务永远红。
#   `--config-only` 只做 compose 派生（不 stat、不 chmod），所以与平台无关。
#
# 前置：`.env` 已生成（`gops sys localize --no-flow --only --no-perms-check`），
#       否则 compose 里的 `${VAR}` 展开不了。CI 里由工作流负责生成。
#
#   dev/check-compose-perms.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v gops >/dev/null 2>&1; then
  echo "SKIP：没有 gops（本检查需要带 --config-only 的 gops）" >&2
  exit 0
fi
if ! gops sys perms --help 2>/dev/null | grep -q -- '--config-only'; then
  echo "SKIP：当前 gops 不支持 --config-only（升级 gops 后本检查自动生效）" >&2
  exit 0
fi
if [ ! -f .env ]; then
  echo "错误：缺少 .env —— compose 里的 \${VAR} 展开不了，派生出来的是空路径（检查等于没做）。" >&2
  echo "  先跑：gops sys localize --no-flow --only --no-perms-check" >&2
  exit 2
fi

gops sys perms --check --config-only
