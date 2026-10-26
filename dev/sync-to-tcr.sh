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
#   # 位置参数最多两个（<src> [<dest>]）；多个镜像请用 -f 清单文件
#
# 前置：
#   - 已安装 skopeo（Debian/Ubuntu: apt-get install -y skopeo）
#     版本不限：`--retry-times` / `--retry-delay` 按 `skopeo copy --help` 实际支持情况取舍
#     （老版本没有 `--retry-delay`，写死会直接 `FATA ... unknown flag` 退出）
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

# `--retry-delay` 不是每个版本都有（现场实测老版本直接 `FATA ... unknown flag` 退出），
# 而且这属于**配置类错误**：重试多少次都一样。所以按实际支持的 flag 拼参数，
# 主重试仍然靠本脚本自己的 for 循环（单次复制内部的 retry 只是抖动掩盖）。
SKOPEO_COPY_HELP="$(skopeo copy --help 2>&1 || true)"
COPY_RETRY_ARGS=()
[[ "${SKOPEO_COPY_HELP}" == *--retry-times* ]] && COPY_RETRY_ARGS+=(--retry-times 3)
[[ "${SKOPEO_COPY_HELP}" == *--retry-delay* ]] && COPY_RETRY_ARGS+=(--retry-delay "${RETRY_DELAY}s")

# 目标引用：未显式给出时 = DEST/<repo 末段>:<tag>
# 注意带端口的写法（host:5000/repo）：不能简单 `%:*`，否则会把端口当 tag 切掉。
dest_ref_for() {
  local ref="${1%%@*}" tag="latest"
  if [[ "${ref##*/}" == *:* ]]; then
    tag="${ref##*:}"
    ref="${ref%:*}"
  fi
  printf '%s/%s:%s' "${DEST}" "${ref##*/}" "${tag}"
}

# 取远端 manifest digest（读不到时**必须返回非零**：否则 `sha256sum` 会把空输入算成
# `e3b0c442…` 这个「合法」的空哈希，让「源不可读 / 目标不存在」的判定全部失效）。
remote_digest() {
  local raw
  raw="$(skopeo inspect --raw --authfile "${AUTHFILE}" "docker://$1" 2>/dev/null)" || return 1
  [[ -n "${raw}" ]] || return 1
  printf '%s' "${raw}" | sha256sum | cut -d' ' -f1
}

sync_one() {
  local src="$1" dest="${2:-}" src_digest dest_digest i
  [[ -n "${dest}" ]] || dest="$(dest_ref_for "${src}")"

  echo
  echo "== ${src}"
  info "目标: ${dest}"

  src_digest="$(remote_digest "${src}")" || { echo "  ❌ 源不可读: ${src}" >&2; return 1; }
  info "源  : sha256:${src_digest}"

  # 读不到目标是**正常**情况（首次同步），不能当错误。
  dest_digest="$(remote_digest "${dest}")" || dest_digest=""
  if [[ "${dest_digest}" == "${src_digest}" ]]; then
    info "状态: 已一致 → 跳过"
    return 0
  fi
  [[ -n "${dest_digest}" ]] && info "状态: digest 不同（覆盖推送）" || info "状态: 目标不存在 → 推送"

  if [[ "${DRY_RUN}" == "1" ]]; then
    info "[dry-run] 不执行复制"
    return 0
  fi

  local out
  for i in $(seq 1 "${RETRIES}"); do
    info "推送中…（第 ${i}/${RETRIES} 次）"
    # `${arr[@]+...}` 写法：空数组在 `set -u` 下也能安全展开（兼容 bash 3.2）。
    if out="$(skopeo copy --all ${COPY_RETRY_ARGS[@]+"${COPY_RETRY_ARGS[@]}"} \
        --authfile "${AUTHFILE}" \
        "docker://${src}" "docker://${dest}" 2>&1)"; then
      dest_digest="$(remote_digest "${dest}")" || dest_digest=""
      if [[ "${dest_digest}" == "${src_digest}" ]]; then
        echo "  ✅ 完成: sha256:${src_digest}"
        return 0
      fi
      echo "  ⚠️  推送返回成功但 digest 不一致（目标 sha256:${dest_digest:-<空>}），重试" >&2
    else
      printf '%s\n' "${out}" | tail -n 5 | sed 's/^/    | /' >&2
      case "${out}" in
        *"unknown flag"*|*"unauthorized"*|*"authentication required"*|*"denied"*)
          echo "  ❌ 配置/鉴权类错误，重试无意义，已放弃：${src}" >&2
          return 1
          ;;
      esac
      echo "  ⚠️  第 ${i} 次失败" >&2
    fi
    sleep $(( i * RETRY_DELAY ))
  done

  echo "  ❌ 重试 ${RETRIES} 次仍未成功" >&2
  return 1
}

# 收集清单
# 位置参数走「一个镜像」的写法 `<src> [<dest>]`（与头部用法一致）；
# 要同步多个镜像用 `-f <清单文件>`，或者把 `"src dest"` 当作单个参数传。
IMAGES=()
if [[ -n "${LIST_FILE}" ]]; then
  [[ -r "${LIST_FILE}" ]] || die "读不到清单文件 ${LIST_FILE}"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "${line}" | xargs)"
    [[ -n "${line}" ]] && IMAGES+=("${line}")
  done < "${LIST_FILE}"
elif [[ ${#ARGS[@]} -eq 1 ]]; then
  IMAGES=("${ARGS[0]}")
elif [[ ${#ARGS[@]} -eq 2 ]]; then
  IMAGES=("${ARGS[0]} ${ARGS[1]}")
elif [[ ${#ARGS[@]} -gt 2 ]]; then
  die "位置参数最多两个（<src> [<dest>]）；要同步多个镜像请用 -f <清单文件>"
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
