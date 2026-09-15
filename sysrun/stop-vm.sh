#!/usr/bin/env bash
# 开发态：停止 VictoriaMetrics（配合 start-vm.sh）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${STACK_ROOT}"
docker compose stop victoria-metrics
