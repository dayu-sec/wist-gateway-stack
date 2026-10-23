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

# `set -e` 的静默退出是排查黑洞：脚本半途死掉、stderr 空白。
# 任何未被 if/&& 接住的失败都把行号打到 stderr。
# 为什么用 $0 / $? 而不用中间变量：`$(basename "$0")` 是**命令替换**，
# 在同一个字符串里先展开它会把 `$?` 冲成 0（已实测），行号与退出码就都错了。
trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_DIR="${STACK_ROOT}/data-plane-run"
TOKEN_HOST="${RUN_DIR}/.run/admin_api.token.host"
LEGACY_TOKEN="${RUN_DIR}/.run/admin_api.token"
VOLUME="${WPARSE_RUN_VOLUME:-wist-gateway-stack-wparse-run}"
IMAGE="${WARP_SPC:-ghcr.io/wp-labs}/warp-parse:${WPARSE_TAG:-0.32.1-alpha}"

# 显式按**宿主架构**钉平台：镜像源里可能只有单一架构（如从 Apple Silicon 用 push-images.sh
# 的 pull 方式推成 arm64-only），本地也可能缓存了异架构的同名 tag。此时 `docker run` 直接
# `exec format error`，报错完全不指向「镜像架构不对」这个真正原因。
HOST_PLATFORM=""
case "$(uname -m)" in
  x86_64 | amd64) HOST_PLATFORM="linux/amd64" ;;
  aarch64 | arm64) HOST_PLATFORM="linux/arm64" ;;
esac
PLATFORM_ARG="${HOST_PLATFORM:+--platform ${HOST_PLATFORM}}"

note() { echo "  $*"; }
warn() { echo "  ⚠ $*" >&2; }

mkdir -p "${RUN_DIR}/work" "${RUN_DIR}/.run" "${RUN_DIR}/data"

# 预建 `work/` 里的**嵌套挂载点**：`/data/data`（bind）、`/data/.run`（命名卷）、
# `/data/identity/{admin-tls.*.pem,trust}`（文件与目录挂载）。
#
# 为什么必须在这里建：父挂载 `${WPARSE_RUN_WORK}:/data` 生效后，子挂载点只能落在
# **宿主**这份工作目录里；缺失时由 Docker 守护进程以 **root** 创建（空目录/空文件）。
# 一旦如此，部署账号既 chown 不动也 chmod 不动 → `gops sys perms --apply` 只会得到
# 整片 `Operation not permitted`（属主 0:999），只能管理员 `sudo chown -R` 收拾。
# 本脚本以部署账号跑，提前建好，Docker 看到已存在就不会再创建。
NESTED_MOUNTS=(
  "${RUN_DIR}/work/data"
  "${RUN_DIR}/work/.run"
  "${RUN_DIR}/work/identity"
  "${RUN_DIR}/work/identity/trust"
)
mkdir -p "${NESTED_MOUNTS[@]}"
NESTED_FILES=(
  "${RUN_DIR}/work/identity/admin-tls.crt.pem"
  "${RUN_DIR}/work/identity/admin-tls.key.pem"
)
for path in "${NESTED_FILES[@]}"; do
  # 旧现场可能因「源缺失」被 Docker 把挂载点建成同名**目录**（与 0.2.9 信任锚同一个坑）：
  # 空的直接清掉（只删空目录），非空的不碰，交给人确认。
  if [[ -d "${path}" ]]; then
    if rmdir "${path}" 2>/dev/null; then
      warn "清掉 Docker 留下的空目录挂载点：${path}"
    else
      warn "${path} 是目录且非空（Docker 残留？），请手工确认后删除，再重跑 localize"
      continue
    fi
  fi
  : >>"${path}"
done

# 老现场（本脚本这一步之前建成的）可能已被 root 占有：非 root 改不动，只能请管理员一次性修。
for path in "${NESTED_MOUNTS[@]}" "${NESTED_FILES[@]}"; do
  if [[ -e "${path}" && ! -O "${path}" ]]; then
    warn "${path} 的属主不是当前部署账号（多由 Docker 以 root 创建）"
    warn "  一次性修复（管理员）：sudo chown -R $(id -u):999 ${RUN_DIR}/work"
    warn "  之后 'gops sys perms --apply' 会把模式收成 0660/2770"
    break
  fi
done

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
if ! docker run --rm -u 0:0 ${PLATFORM_ARG} -v "${VOLUME}:/run" --entrypoint /bin/sh "${IMAGE}" \
  -c 'chown 999:999 /run && chmod 2770 /run' >/dev/null; then
  warn "运行态命名卷初始化失败：${IMAGE}（宿主平台 ${HOST_PLATFORM:-未知}）"
  warn "常见原因：该 tag 在镜像源里缺宿主架构（arm64-only 镜像跑在 amd64 宿主）——"
  warn "  用 ./dev/push-images.sh 重新同步（buildx imagetools 保留多架构），或把 WARP_SPC 指回 ghcr.io/wp-labs"
  exit 1
fi
note "运行态命名卷已对齐 999:999 / 2770：${VOLUME}"

note "WarpParse 管理面：容器 0.0.0.0:19090 + TLS；宿主仅 127.0.0.1:${WPARSE_ADMIN_PORT:-19090}"
note "gwlinkd 读取的 token：${TOKEN_HOST}（0600）"
