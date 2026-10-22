#!/usr/bin/env bash
# 把 agent 安装包**导入投放目录** packages/，并给出「界面该填的容器路径」。
#
# 为什么需要它：网关跑在容器里，**读不到宿主路径**；界面「本地来源」必须是**容器内路径**
# （本栈约定 `/packages/<文件名>`）。本脚本把包放进宿主 `packages/`（只读挂到容器 `/packages`），
# 打印对应容器路径与 sha256；可选用 `--set` 直接调管理 API 把来源设好。
#
# 用法：
#   scripts/import-package.sh <包文件>                # 复制进 packages/
#   scripts/import-package.sh <目录>                  # 取目录里最新的 wist-agentd-*.tar.gz
#   scripts/import-package.sh --latest                # 取 ../wist-agentd/target/package 里最新的
#   scripts/import-package.sh <...> --set             # 顺手把网关来源设为 /packages/<文件名>
#   scripts/import-package.sh <...> --dry-run         # 只打印，不落文件/不发请求
#
# 可覆盖 env：
#   PACKAGE_DIR     投放目录（默认 ./packages）
#   AGENTD_PKG_DIR  --latest 的来源目录（默认 ../wist-agentd/target/package）
#   GATEWAY_URL     管理面基址（默认取 configs/gateway/wist-gateway.value.json 的 public_base_url）
#   ADMIN_TOKEN     管理面 token（默认取密钥文件 .wist/sec-value.yml 的 admin_token）
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${STACK_ROOT}"

PACKAGE_DIR="${PACKAGE_DIR:-./packages}"
VALUE_JSON="${STACK_ROOT}/configs/gateway/wist-gateway.value.json"
# admin token 已从 value.json 移到密钥文件（键 admin_token → SEC_ADMIN_TOKEN）。
SEC_FILE="${WIST_GATEWAY_SEC_FILE:-${STACK_ROOT}/.wist/sec-value.yml}"
AGENTD_PKG_DIR="${AGENTD_PKG_DIR:-${STACK_ROOT}/../wist-agentd/target/package}"

SET=0
DRY_RUN=0
SRC=""
for arg in "$@"; do
  case "$arg" in
    --set) SET=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --latest) SRC="__LATEST__" ;;
    -h | --help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    -*)
      echo "未知参数：${arg}" >&2
      exit 2
      ;;
    *) SRC="$arg" ;;
  esac
done
[[ -n "$SRC" ]] || SRC="__LATEST__"

# 解析来源文件
if [[ "$SRC" == "__LATEST__" ]]; then
  file="$(ls -1t "${AGENTD_PKG_DIR}"/wist-agentd-*.tar.gz 2>/dev/null | head -n1 || true)"
  [[ -n "$file" ]] || {
    echo "在 ${AGENTD_PKG_DIR} 找不到 wist-agentd-*.tar.gz（用 <路径> 显式指定）" >&2
    exit 1
  }
elif [[ -d "$SRC" ]]; then
  file="$(ls -1t "${SRC}"/wist-agentd-*.tar.gz 2>/dev/null | head -n1 || true)"
  [[ -n "$file" ]] || {
    echo "目录 ${SRC} 里没有 wist-agentd-*.tar.gz" >&2
    exit 1
  }
else
  file="$SRC"
fi
[[ -f "$file" ]] || {
  echo "不是文件：${file}" >&2
  exit 1
}

name="$(basename "$file")"
container_path="/packages/${name}"
# sha256：macOS 带的是 shasum，精简 Linux（无 perl）只有 sha256sum —— 与
# diagnose-wparse-drift.sh / show-wparse-state.sh 同一套回落（以前硬编码 shasum，
# 在 alpine 一类宿主上会直接死在这一行）。
if command -v sha256sum >/dev/null 2>&1; then
  HASH="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH="shasum -a 256"
else
  echo "缺少 sha256 工具（sha256sum 或 shasum），无法给出包摘要" >&2
  exit 1
fi
sha="$(${HASH} "$file" | awk '{print $1}')"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "[dry-run] cp ${file} → ${PACKAGE_DIR}/${name}"
else
  mkdir -p "$PACKAGE_DIR"
  cp -f "$file" "${PACKAGE_DIR}/${name}"
  echo "已导入：${PACKAGE_DIR}/${name}"
fi
echo "  界面「本地来源」填：${container_path}"
echo "  sha256：${sha}"

if [[ "$SET" != 1 ]]; then
  exit 0
fi

# 调用管理 API 设置来源
url="${GATEWAY_URL:-}"
token="${ADMIN_TOKEN:-}"
if [[ -f "$VALUE_JSON" ]]; then
  # 不用 `| head -n1`：head 读完一行就关管道，上游 sed 可能吃 SIGPIPE（141）——
  # `set -e` + `pipefail` 下这条命令就无声失败（url 空着，后面报“需要 GATEWAY_URL”）。
  [[ -n "$url" ]] || url="$(sed -n 's/.*"public_base_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VALUE_JSON" | sed -n '1p')"
fi
if [[ -z "$token" && -f "${SEC_FILE}" ]]; then
  token="$(sed -n 's/^[[:space:]]*admin_token:[[:space:]]*//p' "${SEC_FILE}" | sed -n '1p')"
  token="${token%\"}"; token="${token#\"}"; token="${token%\'}"; token="${token#\'}"
fi
[[ -n "$url" ]] || { echo "需要 GATEWAY_URL（或 value.json 的 public_base_url）" >&2; exit 1; }
[[ -n "$token" ]] || { echo "需要 ADMIN_TOKEN（或密钥文件 ${SEC_FILE} 的 admin_token）" >&2; exit 1; }

if [[ "$DRY_RUN" == 1 ]]; then
  echo "[dry-run] POST ${url%/}/api/v1/admin/agent/install-package {\"package_url\":\"${container_path}\",\"package_sha256\":\"sha256:${sha}\"}"
  exit 0
fi
code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST "${url%/}/api/v1/admin/agent/install-package" \
  -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
  -d "{\"package_url\":\"${container_path}\",\"package_sha256\":\"sha256:${sha}\"}")"
echo "  设置来源 → HTTP ${code}"
[[ "$code" == "200" ]] || exit 1
