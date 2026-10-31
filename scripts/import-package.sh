#!/usr/bin/env bash
# 把 agent 安装包**导入投放目录** packages/，并给出「界面该填的容器路径」。
#
# 为什么需要它：网关跑在容器里，**读不到宿主路径**；界面「本地来源」必须是**容器内路径**
# （本栈约定 `/packages/<文件名>`）。本脚本把包放进宿主 `packages/`（只读挂到容器 `/packages`），
# 打印对应容器路径与 sha256；可选用 `--set` 直接调管理 API 把来源设好。
#
# 用法：
#   scripts/import-package.sh <包文件...>             # 复制进 packages/（可一次给多个平台）
#   scripts/import-package.sh <目录>                  # 取该目录里**每平台**最新的 wist-agentd-*.tar.gz
#   scripts/import-package.sh --latest                # 同上，目录取 ../wist-agentd/target/package
#   scripts/import-package.sh <...> --set             # 顺手把网关来源设为 /packages/<文件名>
#   scripts/import-package.sh <...> --dry-run         # 只打印，不落文件/不发请求
#
# 平台名（target triple）从文件名取，必须是 CI 产物的四种之一：
#   aarch64-apple-darwin / x86_64-apple-darwin /
#   aarch64-unknown-linux-musl / x86_64-unknown-linux-musl
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

# `--set` 的请求体是**按平台**的一组制品（网关 v0.28+ 的形状）：
#   {"artifacts":[{"platform","package_url","package_sha256"}],"requested_by"}
# 旧脚本发的是平铺 `{package_url, package_sha256}`，在 v0.29 上必然 422
# （`missing field artifacts`）—— 现场表现是「包放进去了，但来源一直设不上」。
KNOWN_PLATFORMS=(
  "aarch64-apple-darwin"
  "x86_64-apple-darwin"
  "aarch64-unknown-linux-musl"
  "x86_64-unknown-linux-musl"
)

SET=0
DRY_RUN=0
LATEST=0
SRC_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --set) SET=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --latest) LATEST=1 ;;
    -h | --help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    -*)
      echo "未知参数：${arg}" >&2
      exit 2
      ;;
    *) SRC_ARGS+=("$arg") ;;
  esac
done

# 最终文件清单用**换行分隔的字符串**：macOS 自带 bash 3.2 没有 `mapfile`，
# 且 `set -u` 下空数组 `"${arr[@]}"` 会报 unbound variable。
FILES=""
add_file() { FILES="${FILES}$1"$'\n'; }

# 从文件名取平台名：`wist-agentd-v0.13.1-alpha-aarch64-apple-darwin.tar.gz`
# → `aarch64-apple-darwin`。版本段本身也带连字符（`0.13.1-alpha`），
# 不能「按最后一个连字符切」—— 用已知 triple 做后缀匹配。
platform_of() {
  local base
  base="$(basename "$1")"
  base="${base%.tar.gz}"
  local triple
  for triple in "${KNOWN_PLATFORMS[@]}"; do
    case "$base" in
      *-"${triple}") printf '%s' "$triple"; return 0 ;;
    esac
  done
  return 1
}

# 目录里**每个平台**各取最新的一个：只取最新那一个文件，会让另外两种架构的机器
# 拿到错平台的包（网关会以 platform_mismatch 拒收）。
collect_latest() {
  local dir="$1"
  local triple newest found=0
  for triple in "${KNOWN_PLATFORMS[@]}"; do
    newest="$(ls -1t "${dir}"/wist-agentd-*-"${triple}".tar.gz 2>/dev/null | sed -n '1p' || true)"
    if [[ -n "${newest}" ]]; then
      add_file "${newest}"
      found=1
    fi
  done
  [[ "${found}" == 1 ]] || {
    echo "在 ${dir} 找不到 wist-agentd-<平台>.tar.gz（用 <路径> 显式指定）" >&2
    exit 1
  }
}

resolve_source() {
  if [[ -d "$1" ]]; then
    collect_latest "$1"
  else
    add_file "$1"
  fi
}

if [[ "${LATEST}" == 1 || "${#SRC_ARGS[@]}" -eq 0 ]]; then
  collect_latest "${AGENTD_PKG_DIR}"
fi
for src in ${SRC_ARGS[@]+"${SRC_ARGS[@]}"}; do
  resolve_source "${src}"
done

# 去重：同一个包既显式给了、又命中 --latest 时只导一次。
FILES="$(printf '%s\n' "${FILES}" | awk 'NF && !seen[$0]++')"
[[ -n "${FILES}" ]] || {
  echo "没有可导入的包" >&2
  exit 1
}

while IFS= read -r file; do
  [[ -f "${file}" ]] || {
    echo "不是文件：${file}" >&2
    exit 1
  }
done <<< "${FILES}"

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

ARTIFACTS=""
while IFS= read -r file; do
  name="$(basename "${file}")"
  container_path="/packages/${name}"
  platform="$(platform_of "${file}")" || {
    echo "无法从文件名判断平台：${name}" >&2
    echo "  文件名要像 wist-agentd-v0.13.1-alpha-aarch64-apple-darwin.tar.gz" >&2
    echo "  可用平台：${KNOWN_PLATFORMS[*]}" >&2
    exit 1
  }
  sha="$(${HASH} "${file}" | awk '{print $1}')"

  if [[ "${DRY_RUN}" == 1 ]]; then
    echo "[dry-run] cp ${file} → ${PACKAGE_DIR}/${name}"
  else
    mkdir -p "${PACKAGE_DIR}"
    cp -f "${file}" "${PACKAGE_DIR}/${name}"
    echo "已导入：${PACKAGE_DIR}/${name}"
  fi
  echo "  平台：${platform}"
  echo "  界面「本地来源」填：${container_path}"
  echo "  sha256：${sha}"

  [[ -z "${ARTIFACTS}" ]] || ARTIFACTS+=","
  ARTIFACTS+="{\"platform\":\"${platform}\",\"package_url\":\"${container_path}\",\"package_sha256\":\"sha256:${sha}\"}"
done <<< "${FILES}"

if [[ "${SET}" != 1 ]]; then
  exit 0
fi

# 调用管理 API 设置来源
url="${GATEWAY_URL:-}"
token="${ADMIN_TOKEN:-}"
if [[ -f "${VALUE_JSON}" ]]; then
  # 不用 `| head -n1`：head 读完一行就关管道，上游 sed 可能吃 SIGPIPE（141）——
  # `set -e` + `pipefail` 下这条命令就无声失败（url 空着，后面报“需要 GATEWAY_URL”）。
  [[ -n "${url}" ]] || url="$(sed -n 's/.*"public_base_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${VALUE_JSON}" | sed -n '1p')"
fi
if [[ -z "${token}" && -f "${SEC_FILE}" ]]; then
  token="$(sed -n 's/^[[:space:]]*admin_token:[[:space:]]*//p' "${SEC_FILE}" | sed -n '1p')"
  token="${token%\"}"; token="${token#\"}"; token="${token%\'}"; token="${token#\'}"
fi
[[ -n "${url}" ]] || { echo "需要 GATEWAY_URL（或 value.json 的 public_base_url）" >&2; exit 1; }
[[ -n "${token}" ]] || { echo "需要 ADMIN_TOKEN（或密钥文件 ${SEC_FILE} 的 admin_token）" >&2; exit 1; }

BODY="{\"artifacts\":[${ARTIFACTS}],\"requested_by\":\"scripts/import-package.sh\"}"

if [[ "${DRY_RUN}" == 1 ]]; then
  echo "[dry-run] POST ${url%/}/api/v1/admin/agent/install-package ${BODY}"
  exit 0
fi
# 404/422 的正文里带着「哪个平台/哪个地址/为什么」—— 不要只打印状态码，
# 否则现场只看得到「HTTP 422」，分不出是形状不对还是包不对。
response="$(curl -sk -X POST "${url%/}/api/v1/admin/agent/install-package" \
  -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
  -d "${BODY}" -w '\n%{http_code}')"
code="$(printf '%s\n' "${response}" | tail -n1)"
body="$(printf '%s\n' "${response}" | sed '$d')"
echo "  设置来源 → HTTP ${code}"
if [[ "${code}" != "200" ]]; then
  echo "  网关返回：${body}" >&2
  exit 1
fi
