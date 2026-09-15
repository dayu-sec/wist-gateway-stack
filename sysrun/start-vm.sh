#!/usr/bin/env bash
# 开发态：仅启动 VictoriaMetrics（第三方依赖，无本地二进制，用 Docker 起）。
# 端口与发布态 compose 对齐：宿主 18429 -> 容器 8428。
#
# 用法：
#   ./sysrun/start-vm.sh
#
# 仅拉起 victoria-metrics 一个服务，不影响 gateway / web / wparse。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${STACK_ROOT}"
docker compose up -d victoria-metrics
echo
docker compose ps victoria-metrics
