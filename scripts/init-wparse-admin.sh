#!/usr/bin/env bash
# WarpParse 管理面备料（由 localize 阶段流程调用，幂等）。
#
# 做的事：
#   1) 建可写运行根 data-plane-run/work 与运行态目录；
#   2) 生成 admin API bearer token → data-plane-run/.run/admin_api.token.host（缺失才生成）；
#   3) 创建并初始化 wparse 运行态命名卷（wist-gateway-stack-wparse-run，999:999 / 2770）。
#
# 为什么不把 token 直接放 bind 挂载的 .run/：
#   · WarpParse 要求 token 文件 **0600 且属主=运行用户**；
#   · `gops sys perms` 会把 bind 挂载里的文件统一成 0660（owner=部署账号、group=999）；
#   · 两者冲突。因此容器内 token 放在**命名卷**，由 wparse-run-init 以 999 身份复制并 chmod 600；
#     宿主这份 `.host` 属主=部署账号、0600，留给 gwlinkd 读。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_DIR="${STACK_ROOT}/data-plane-run"
TOKEN_HOST="${RUN_DIR}/.run/admin_api.token.host"
LEGACY_TOKEN="${RUN_DIR}/.run/admin_api.token"
VOLUME="${WPARSE_RUN_VOLUME:-wist-gateway-stack-wparse-run}"
IMAGE="${WARP_SPC:-ghcr.io/wp-labs}/warp-parse:${WPARSE_TAG:-0.32.1-alpha}"

note() { echo "  $*"; }
warn() { echo "  ⚠ $*" >&2; }

mkdir -p "${RUN_DIR}/work" "${RUN_DIR}/.run" "${RUN_DIR}/data"

if [[ -f "${TOKEN_HOST}" && -s "${TOKEN_HOST}" ]]; then
  note "admin API token 已存在，跳过：${TOKEN_HOST}"
else
  tmp="$(mktemp "${RUN_DIR}/.run/.admin_api.token.host.XXXXXX")"
  if [[ -s "${LEGACY_TOKEN}" ]]; then
    # 迁移：旧脚本把 token 直接写在 bind 挂载的 .run/ 里。
    cp -f "${LEGACY_TOKEN}" "${tmp}"
  else
    python3 -c 'import secrets; print(secrets.token_hex(32))' >"${tmp}"
  fi
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${TOKEN_HOST}"
  note "已生成 admin API token（宿主侧）：${TOKEN_HOST}"
fi

if ! command -v docker >/dev/null 2>&1; then
  warn "找不到 docker：跳过运行态命名卷初始化（首次 start 前需手动执行）"
  exit 0
fi

if ! docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
  docker volume create "${VOLUME}" >/dev/null
  note "已创建运行态命名卷：${VOLUME}"
fi

# 命名卷默认 root:root；wparse 以 999 运行，需要可写。
docker run --rm -u 0:0 -v "${VOLUME}:/run" --entrypoint /bin/sh "${IMAGE}" \
  -c 'chown 999:999 /run && chmod 2770 /run' >/dev/null
note "运行态命名卷已对齐 999:999 / 2770：${VOLUME}"

note "WarpParse 管理面：容器 0.0.0.0:19090 + TLS；宿主仅 127.0.0.1:${WPARSE_ADMIN_PORT:-19090}"
note "gwlinkd 读取的 token：${TOKEN_HOST}（0600）"
