#!/usr/bin/env bash
# 把镜像从一个 registry 同步到 TCR（多架构、幂等、失败重试、digest 校验）。
#
# 为什么不用 docker pull/tag/push：那会丢掉多架构 index，只推当前宿主平台；
# 这里用 skopeo 做 registry→registry 的 manifest 级复制，digest 与源完全一致。
#
# 用法：
#   ./dev/sync-to-tcr.sh                            # 同步内置清单
#   ./dev/sync-to-tcr.sh ghcr.io/wp-labs/warp-parse:0.32.1-alpha
#   ./dev/sync-to-tcr.sh -f images.txt              # 每行 "<src> [<dest>]"
#   ./dev/sync-to-tcr.sh -n ...                     # 只检查，不推送
#
# 示例：
#   # 单镜像
#   ./dev/sync-to-tcr.sh ghcr.io/wp-labs/warp-parse:0.32.1-alpha
#
#   # 指定目标（默认 DEST/<repo 末段>:<tag>）
#   ./dev/sync-to-tcr.sh ghcr.io/wp-labs/warp-parse:0.32.1-alpha \
#       dy-sec.tencentcloudcr.com/cloud/warp-parse:0.32.1-alpha
#
#   # 换目标仓库 / 重试次数
#   DEST=hk.example.com/cloud RETRIES=20 ./dev/sync-to-tcr.sh
#
# 前置：
#   - 已安装 skopeo（Debian/Ubuntu: apt-get install -y skopeo）
#   - 已 docker login dy-sec.tencentcloudcr.com（凭据默认复用 ~/.docker/config.json）
set -uo pipefail

DEST="${DEST:-dy-sec.tencentcloudcr.com/cloud}"
AUTHFILE="${AUTHFILE:-$HOME/.docker/config.json}"
RETRIES="${RETRIES:-10}"
RETRY_DELAY="${RETRY_DELAY:-5}"

# 内置清单（手动同步时改这里即可）
DEFAULT_IMAGES=(
  "ghcr.io/wp-labs/warp-parse:0.32.1-alpha"
)

DRY_RUN=0
LIST_FILE=""
ARGS=()

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -f|--file) LIST_FILE="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "未知选项: $1" >&2; usage 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

die() { echo "错误: $*" >&2; exit 1; }
info() { echo "  $*"; }

command -v skopeo >/dev/null 2>&1 || die "缺少 skopeo（apt-get install -y skopeo）"
[[ -r "${AUTHFILE}" ]] || die "找不到凭据文件 ${AUTHFILE}（先 docker login dy-sec.tencentcloudcr.com）"

# 目标引用：未显式给出时 = DEST/<repo 末段>:<tag>
dest_ref_for() {
  local src="$1" repo name tag
  repo="${src%:*}"; name="${repo##*/}"; tag="${src##*:}"
  printf '%s/%s:%s' "${DEST}" "${name}" "${tag}"
}

# 取远端 manifest digest（不存在时输出空）
remote_digest() {
  skopeo inspect --raw --authfile "${AUTHFILE}" "docker://$1" 2>/dev/null | sha256sum | cut -d' ' -f1
}

sync_one() {
  local src="$1" dest="${2:-}" src_digest dest_digest i
  [[ -n "${dest}" ]] || dest="$(dest_ref_for "${src}")"

  echo
  echo "== ${src}"
  info "目标: ${dest}"

  src_digest="$(remote_digest "${src}")"
  [[ -n "${src_digest}" ]] || { echo "  ❌ 源不可读: ${src}" >&2; return 1; }
  info "源  : sha256:${src_digest}"

  dest_digest="$(remote_digest "${dest}")"
  if [[ "${dest_digest}" == "${src_digest}" ]]; then
    info "状态: 已一致 → 跳过"
    return 0
  fi
  [[ -n "${dest_digest}" ]] && info "状态: digest 不同（覆盖推送）" || info "状态: 目标不存在 → 推送"

  if [[ "${DRY_RUN}" == "1" ]]; then
    info "[dry-run] 不执行复制"
    return 0
  fi

  for i in $(seq 1 "${RETRIES}"); do
    info "推送中…（第 ${i}/${RETRIES} 次）"
    if skopeo copy --all \
        --retry-times 3 --retry-delay "${RETRY_DELAY}s" \
        --authfile "${AUTHFILE}" \
        "docker://${src}" "docker://${dest}"; then
      dest_digest="$(remote_digest "${dest}")"
      if [[ "${dest_digest}" == "${src_digest}" ]]; then
        echo "  ✅ 完成: sha256:${src_digest}"
        return 0
      fi
      echo "  ⚠️  推送返回成功但 digest 不一致（目标 sha256:${dest_digest:-<空>}），重试" >&2
    else
      echo "  ⚠️  第 ${i} 次失败" >&2
    fi
    sleep $(( i * RETRY_DELAY ))
  done

  echo "  ❌ 重试 ${RETRIES} 次仍未成功" >&2
  return 1
}

# 收集清单
IMAGES=()
if [[ -n "${LIST_FILE}" ]]; then
  [[ -r "${LIST_FILE}" ]] || die "读不到清单文件 ${LIST_FILE}"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "${line}" | xargs)"
    [[ -n "${line}" ]] && IMAGES+=("${line}")
  done < "${LIST_FILE}"
elif [[ ${#ARGS[@]} -gt 0 ]]; then
  IMAGES=("${ARGS[@]}")
else
  IMAGES=("${DEFAULT_IMAGES[@]}")
fi

echo "同步 → ${DEST}（清单 ${#IMAGES[@]} 项，重试 ${RETRIES} 次）"

fail=0
for entry in "${IMAGES[@]}"; do
  # 每行可以是 "src" 或 "src dest"
  read -r src dest <<< "${entry}"
  sync_one "${src}" "${dest:-}" || fail=$((fail + 1))
done

echo
if [[ "${fail}" -gt 0 ]]; then
  echo "结果: ${fail} 项失败" >&2
  exit 1
fi
echo "结果: 全部完成"
