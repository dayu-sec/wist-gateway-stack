#!/usr/bin/env bash
# 录入 / 查看**审批终端（wist-approve）安装包** —— 走网关的包管理，语义与 agent 安装包一致：
#   拿到包 → 拷进投放目录（`packages/`，只读挂到容器 `/packages`）→ 登记「容器内路径」为来源
#   → 网关拉取并缓存 → 分发端点只读缓存（install.sh 内嵌的 sha256 与发出的字节同源）。
#
# 为什么不再直接往 `state/approver-package/` 里丢文件：那样网关不知道「盘上这份是什么版本」，
# 也就没法做「录入 / 查看 / 撤销」；现在与 agent 包同一条链，管理面能回答这三个问题。
#
# 用法：
#   scripts/install-approver-package.sh --tag v0.58.0-alpha   # 从 Release 下载三平台并登记
#   scripts/install-approver-package.sh --from ./downloads    # 离线：用本地 tar.gz
#   scripts/install-approver-package.sh --check               # 只看网关当前登记了什么
#   任一命令加 --dry-run                                      # 只打印，不拷文件、不发请求
#
# 可覆盖 env（与 import-package.sh 同义）：
#   PACKAGE_DIR   投放目录（默认 ./packages）
#   GATEWAY_URL   管理面基址（默认取 configs/gateway/wist-gateway.value.json 的 public_base_url）
#   ADMIN_TOKEN   管理面 token（默认取密钥文件 .wist/sec-value.yml 的 admin_token）
#   APPROVER_ARTIFACT_BASE  制品源基址（含仓库+渠道；默认 GitHub Release，可换 COS 镜像）
set -euo pipefail

trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PACKAGE_DIR="${PACKAGE_DIR:-${STACK_ROOT}/packages}"
# 容器里 packages/ 的挂载点（与 import-package.sh 同约定）。
CONTAINER_PACKAGE_DIR="/packages"
PLATFORMS=(aarch64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl)
APPROVER_ARTIFACT_BASE="${APPROVER_ARTIFACT_BASE:-https://github.com/dayu-sec/wist-approve/releases/download}"
APPROVER_ARTIFACT_BASE="${APPROVER_ARTIFACT_BASE%/}"

TAG="${GATEWAY_TAG:-}"
FROM_DIR=""
CHECK_ONLY=0
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --from) FROM_DIR="${2:-}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) awk 'NR>1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

note() { printf '  %s\n' "$*"; }

# 管理面基址与 token：与 import-package.sh 同一套取法（现场不用手填）。
VALUE_JSON="${WIST_GATEWAY_VALUE_JSON:-${STACK_ROOT}/configs/gateway/wist-gateway.value.json}"
SEC_FILE="${WIST_GATEWAY_SEC_FILE:-${STACK_ROOT}/.wist/sec-value.yml}"
url="${GATEWAY_URL:-}"
token="${ADMIN_TOKEN:-}"
if [ -f "$VALUE_JSON" ]; then
  [ -n "$url" ] || url="$(sed -n 's/.*"public_base_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VALUE_JSON" | sed -n '1p')"
fi
if [ -f "$SEC_FILE" ]; then
  [ -n "$token" ] || token="$(sed -n 's/^[[:space:]]*admin_token:[[:space:]]*//p' "$SEC_FILE" | sed -n '1p')"
fi
url="${url%/}"

api() { printf '%s/api/v1/admin/approver/install-package' "$url"; }

if [ "$CHECK_ONLY" -eq 1 ]; then
  [ -n "$url" ] || { echo "需要 GATEWAY_URL（或 value.json 的 public_base_url）" >&2; exit 1; }
  [ -n "$token" ] || { echo "需要 ADMIN_TOKEN（或密钥文件 $SEC_FILE 的 admin_token）" >&2; exit 1; }
  response="$(curl -sk -H "Authorization: Bearer ${token}" "$(api)")"
  printf '%s\n' "" | grep -q '"packages"' || {
    echo "读取失败：${response}" >&2
    exit 1
  }
  printf '%s\n' "$response"
  echo
  echo "提示：记录存在但 available=false 表示缓存副本不在了（重新登记即可）。"
  exit 0
fi

[ -n "$url" ] || { echo "需要 GATEWAY_URL（或 value.json 的 public_base_url）" >&2; exit 1; }
[ -n "$token" ] || { echo "需要 ADMIN_TOKEN（或密钥文件 $SEC_FILE 的 admin_token）" >&2; exit 1; }
if [ -z "$FROM_DIR" ] && [ -z "$TAG" ]; then
  echo "没有 tag：请给 --tag，或在 .env 里设置 GATEWAY_TAG，或用 --from <目录>" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

placed=0
failed=0
mkdir -p "$PACKAGE_DIR"

for platform in "${PLATFORMS[@]}"; do
  name="wist-approve-${TAG}-${platform}.tar.gz"
  src=""
  if [ -n "$FROM_DIR" ]; then
    for candidate in "${FROM_DIR}/${name}" "${FROM_DIR}/wist-approve-"*"-${platform}.tar.gz"; do
      if [ -f "$candidate" ]; then src="$candidate"; break; fi
    done
    if [ -z "$src" ]; then
      echo "本地找不到 ${platform} 的制品（${FROM_DIR}）—— 跳过" >&2
      failed=$((failed + 1))
      continue
    fi
  else
    download="${APPROVER_ARTIFACT_BASE}/${TAG}/${name}"
    note "下载 ${platform} ← ${download}"
    # dry-run 不碰网络：只把 URL 与将要发的请求打出来（这也让 URL 形状可测）。
    if [ "$DRY_RUN" -eq 1 ]; then
      note "[dry-run] POST $(api) {\"platform\":\"${platform}\",\"source\":\"${CONTAINER_PACKAGE_DIR}/${name}\"}"
      placed=$((placed + 1))
      continue
    fi
    src="${WORK_DIR}/${name}"
    if ! curl -fsSL "$download" -o "$src"; then
      echo "下载失败：${download}（可用 --from 走离线）" >&2
      failed=$((failed + 1))
      continue
    fi
  fi
  [ -s "$src" ] || { echo "空制品：${src}" >&2; failed=$((failed + 1)); continue; }

  dest="${PACKAGE_DIR}/$(basename "$src")"
  if [ "$DRY_RUN" -eq 1 ]; then
    note "[dry-run] 拷贝 $(basename "$src") → ${PACKAGE_DIR}/"
  else
    cp -f "$src" "$dest.tmp" && mv -f "$dest.tmp" "$dest"
  fi

  body="$(printf '{"platform":"%s","source":"%s/%s","requested_by":"stack-install-approver-package"}' \
    "$platform" "$CONTAINER_PACKAGE_DIR" "$(basename "$src")")"
  if [ "$DRY_RUN" -eq 1 ]; then
    note "[dry-run] POST $(api) ${body}"
    placed=$((placed + 1))
    continue
  fi
  response="$(curl -sk -X POST -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' -d "$body" "$(api)")"
  case "$response" in
    *'"platform"'*) note "已登记 ${platform}" ; placed=$((placed + 1)) ;;
    *)
      echo "登记 ${platform} 失败：${response}" >&2
      failed=$((failed + 1))
      ;;
  esac
done

echo
if [ "$failed" -gt 0 ]; then
  echo "共 ${failed} 个平台未能登记（成功 ${placed}）。修好后重跑。"
  exit 1
fi
echo "三个平台都已登记（网关已拉取并缓存）。审批人那条命令现在就能用："
echo "  curl -fsSLk '${url}/api/v1/approver/install/<triple>/install.sh' | sh"
