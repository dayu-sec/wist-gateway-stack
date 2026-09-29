#!/usr/bin/env bash
# 开发态：停止 VictoriaMetrics（配合 start-vm.sh）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${STACK_ROOT}"
# compose 在 sys/ 下（与 start-vm.sh 一致）
docker compose --project-directory . -f sys/docker-compose.yml stop victoria-metrics
