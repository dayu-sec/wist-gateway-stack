#!/usr/bin/env bash
# 把**知识库内容包**导入投放目录 packages/，并给出「管理面该填的容器路径」。
#
# 为什么需要它：网关跑在容器里，**读不到宿主路径**；管理面「来源」必须是**容器内路径**
# （本栈约定 `/packages/<文件名>`）。与 `import-package.sh` 同一套做法，只是落到
# 知识库那组端点上 —— 而且知识库是**录入 ≠ 生效**：默认只录入，要 `--activate` 才切指针。
#
# 用法：
#   scripts/import-knowledge.sh <包文件>                 # 复制进 packages/（不调 API）
#   scripts/import-knowledge.sh <目录>                   # 取目录里最新的 wist-knowledge-*.tar.gz
#   scripts/import-knowledge.sh --latest                 # 取 ../wist-knowledge/dist 里最新的
#   scripts/import-knowledge.sh <...> --set              # 顺手录入（不生效）
#   scripts/import-knowledge.sh <...> --set --activate   # 录入并**当场切生效**
#   scripts/import-knowledge.sh <...> --dry-run          # 只打印，不落文件/不发请求
#
# 可覆盖 env：
#   PACKAGE_DIR        投放目录（默认 ./packages）
#   KNOWLEDGE_PKG_DIR  --latest 的来源目录（默认 ../wist-knowledge/dist）
#   GATEWAY_URL        管理面基址（默认取 configs/gateway/wist-gateway.value.json 的 public_base_url）
#   ADMIN_TOKEN        管理面 token（默认取同一 value.json 的 admin_api_token）
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${STACK_ROOT}"

PACKAGE_DIR="${PACKAGE_DIR:-./packages}"
VALUE_JSON="${STACK_ROOT}/configs/gateway/wist-gateway.value.json"
KNOWLEDGE_PKG_DIR="${KNOWLEDGE_PKG_DIR:-${STACK_ROOT}/../wist-knowledge/dist}"

SET=0
ACTIVATE=0
DRY_RUN=0
SRC=""
for arg in "$@"; do
  case "$arg" in
    --set) SET=1 ;;
    --activate) ACTIVATE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --latest) SRC="__LATEST__" ;;
    -h | --help)
      sed -n '2,21p' "$0"
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
# `--activate` 隐含 `--set`：不录入就切不了。
[[ "$ACTIVATE" == 1 ]] && SET=1

# 解析来源文件
if [[ "$SRC" == "__LATEST__" ]]; then
  file="$(ls -1t "${KNOWLEDGE_PKG_DIR}"/wist-knowledge-*.tar.gz 2>/dev/null | head -n1 || true)"
  [[ -n "$file" ]] || {
    echo "在 ${KNOWLEDGE_PKG_DIR} 找不到 wist-knowledge-*.tar.gz（用 <路径> 显式指定，或先跑 wist-knowledge/scripts/package.sh）" >&2
    exit 1
  }
elif [[ -d "$SRC" ]]; then
  file="$(ls -1t "${SRC}"/wist-knowledge-*.tar.gz 2>/dev/null | head -n1 || true)"
  [[ -n "$file" ]] || {
    echo "目录 ${SRC} 里没有 wist-knowledge-*.tar.gz" >&2
    exit 1
  }
else
  file="$SRC"
fi
[[ -f "$file" ]] || {
  echo "不是文件：${file}（知识库要的是 tar.gz **制品**，不是解开的目录）" >&2
  exit 1
}

name="$(basename "$file")"
container_path="/packages/${name}"
sha="$(shasum -a 256 "$file" | awk '{print $1}')"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "[dry-run] cp ${file} → ${PACKAGE_DIR}/${name}"
else
  mkdir -p "$PACKAGE_DIR"
  cp -f "$file" "${PACKAGE_DIR}/${name}"
  echo "已导入：${PACKAGE_DIR}/${name}"
fi
echo "  管理面「来源」填：${container_path}"
echo "  sha256：${sha}"

if [[ "$SET" != 1 ]]; then
  exit 0
fi

# 调用管理 API 录入（可选再激活）
url="${GATEWAY_URL:-}"
token="${ADMIN_TOKEN:-}"
if [[ -f "$VALUE_JSON" ]]; then
  [[ -n "$url" ]] || url="$(sed -n 's/.*"public_base_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VALUE_JSON" | head -n1)"
  [[ -n "$token" ]] || token="$(sed -n 's/.*"admin_api_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VALUE_JSON" | head -n1)"
fi
[[ -n "$url" ]] || { echo "需要 GATEWAY_URL（或 value.json 的 public_base_url）" >&2; exit 1; }
[[ -n "$token" ]] || { echo "需要 ADMIN_TOKEN（或 value.json 的 admin_api_token）" >&2; exit 1; }

# 摘要一起交上去：网关会拿它核对读到的字节 —— 拷贝被截断/挂载没同步，在这里就暴露。
activate_flag="false"
[[ "$ACTIVATE" == 1 ]] && activate_flag="true"
payload="{\"source\":\"${container_path}\",\"sha256\":\"${sha}\",\"activate\":${activate_flag}}"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "[dry-run] POST ${url%/}/api/v1/admin/knowledge/packages ${payload}"
  exit 0
fi
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
code="$(curl -sk -o "$body" -w '%{http_code}' -X POST "${url%/}/api/v1/admin/knowledge/packages" \
  -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
  -d "${payload}")"
echo "  录入 → HTTP ${code}"
if [[ "$code" != "200" ]]; then
  cat "$body"
  exit 1
fi
if command -v python3 >/dev/null 2>&1; then
  python3 - "$body" <<'PY'
import json, sys
view = json.load(open(sys.argv[1]))
print(f"  package_id={view.get('package_id')} version={view.get('version')} active={view.get('active')}")
print(f"  内容版本：catalog={view.get('catalog_version')} template={view.get('template_version')} "
      f"policy={view.get('policy_version')} purpose={view.get('purpose_version')}")
if not view.get("active"):
    print("  提示：已录入但**未生效** —— 到「知识库」页点激活，或重跑加 --activate")
PY
fi
