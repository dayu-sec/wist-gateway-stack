#!/usr/bin/env bash
# 门禁：审批终端投放脚本 `scripts/install-approver-package.sh`。
#
# 这个脚本决定「审批人能不能从网关下载到 wist-approve」。它写错时**不会报错**，
# 只会静默地把文件放到网关不读的目录里（下载端点恒 503），所以钉住四件事：
#
#   1. **triple 表白名单化**：必须正好是网关分发白名单那三个（musl 静态 + macOS arm）。
#      网关侧有对称的一条测试（`approver_install.rs` 的
#      `install_script_handles_every_whitelisted_platform`），两边一起把「白名单改了、
#      这边没跟」钉死在测试里 —— 2026-11 就撞过一次：白名单 musl、CI 与脚本写 gnu。
#   2. **幂等**：同内容重跑不重写（mtime 不变），新内容才覆盖。
#   3. **带前缀目录的 tarball** 也能解开（离线包常常是 `<name>/wist-approve`）。
#   4. **部分失败不写 VERSION**：盘上是混合版本时，不能对外宣称「投放版本 = 某个 tag」。
#
# 跑法：`dev/tests/install-approver-package.test.sh`（CI 里由 scripts.yml 全量跑）
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
SCRIPT="${STACK_ROOT}/scripts/install-approver-package.sh"
[[ -f "${SCRIPT}" ]] || { echo "missing script: ${SCRIPT}" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM

STATE="${TMP}/state"
SRC="${TMP}/src"
mkdir -p "${SRC}"
# 所有调用（含 run 包装）都落到临时目录：否则测完会把文件投进仓库的 state，
# 污染下一次手动 `--check` 的结果。
export APPROVER_PACKAGE_DIR="${STATE}"

TAG="v9.9.9-alpha"
EXPECTED_PLATFORMS=(aarch64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl)

fail() { echo "FAIL $*" >&2; exit 1; }

mode_of() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

mtime_of() {
  case "$(uname -s)" in
    Darwin) stat -f '%m' "$1" ;;
    *) stat -c '%Y' "$1" ;;
  esac
}

run() { # run <label> <args...>；非零退出即失败
  local label="$1"
  shift
  if ! "${SCRIPT}" "$@" >"${TMP}/out" 2>&1; then
    echo "FAIL ${label}" >&2
    cat "${TMP}/out" >&2
    exit 1
  fi
}

# 造一个只有可执行假二进制的 tarball（内容按平台区分，便于核对投的是哪一份）。
make_tarball() { # make_tarball <platform> <content> [prefix]
  local platform="$1" content="$2" prefix="${3:-}"
  local work="${TMP}/work-${platform}-${RANDOM}"
  mkdir -p "${work}"
  local name="wist-approve"
  if [[ -n "${prefix}" ]]; then
    mkdir -p "${work}/${prefix}"
    name="${prefix}/wist-approve"
  fi
  printf '%s\n' "${content}" >"${work}/${name}"
  tar -czf "${SRC}/wist-approve-${TAG}-${platform}.tar.gz" -C "${work}" "${name}"
}

# ── 1. triple 表 ─────────────────────────────────────────────────────────────
grep -q '^PLATFORMS=(' "${SCRIPT}" || fail "脚本里没有 PLATFORMS 数组"
declared="$(grep '^PLATFORMS=(' "${SCRIPT}" | sed 's/^PLATFORMS=(//; s/)$//')"
for platform in "${EXPECTED_PLATFORMS[@]}"; do
  case " ${declared} " in
    *" ${platform} "*) ;;
    *) fail "PLATFORMS 缺 ${platform}（现为：${declared}）" ;;
  esac
done
for platform in ${declared}; do
  case " ${EXPECTED_PLATFORMS[*]} " in
    *" ${platform} "*) ;;
    *) fail "PLATFORMS 里有白名单外的 ${platform}（网关不会读那个目录，下载恒 503）" ;;
  esac
done
case "${declared}" in
  *gnu*) fail "Linux 制品必须是 musl（gnu 在客户老系统上跑不起来）" ;;
esac

# ── 2. 缺制品时 --check 必须非零（并说清后果）────────────────────────────────
if "${SCRIPT}" --check >"${TMP}/out" 2>&1; then
  fail "--check 在什么都没投放时应当失败"
fi
grep -q '503' "${TMP}/out" || fail "--check 失败时应当说明后果（503）"

# ── 3. 部分失败：不该写 VERSION ──────────────────────────────────────────────
make_tarball aarch64-apple-darwin 'fake-darwin-v1'
if "${SCRIPT}" --from "${SRC}" --tag "${TAG}" >"${TMP}/out" 2>&1; then
  fail "只给了一个平台的制品时应当失败（其余平台缺）"
fi
[[ -f "${STATE}/aarch64-apple-darwin/wist-approve" ]] || fail "已给的那个平台应当照常投放"
# 注意别写成 `[[ -f x ]] && fail`：文件不存在时整句返回 1，set -e 会静静退出。
if [[ -f "${STATE}/VERSION" ]]; then
  fail "部分失败时不该写 VERSION（盘上是混合版本）"
fi

# ── 4. 全部就位：写 VERSION，权限 0644，幂等 ─────────────────────────────────
make_tarball x86_64-unknown-linux-musl 'fake-linux-x86-v1'
make_tarball aarch64-unknown-linux-musl 'fake-linux-arm-v1'
run "全量投放" --from "${SRC}" --tag "${TAG}"
for platform in "${EXPECTED_PLATFORMS[@]}"; do
  dest="${STATE}/${platform}/wist-approve"
  [[ -f "${dest}" ]] || fail "缺 ${platform}/wist-approve"
  [[ "$(mode_of "${dest}")" == "644" ]] || fail "${platform} 权限应为 0644（容器读得到即可）"
done
[[ "$(cat "${STATE}/VERSION")" == "${TAG}" ]] || fail "VERSION 应记为 ${TAG}"

before="$(mtime_of "${STATE}/aarch64-apple-darwin/wist-approve")"
sleep 1
run "同内容重跑" --from "${SRC}" --tag "${TAG}"
grep -q '已是最新' "${TMP}/out" || fail "同内容重跑应当说明「已是最新」，而不是静默重写"
[[ "$(mtime_of "${STATE}/aarch64-apple-darwin/wist-approve")" == "${before}" ]] ||
  fail "同内容重跑不该重写文件（幂等）"

run "check（全就位）" --check --tag "${TAG}"
grep -q "投放版本 ${TAG}" "${TMP}/out" || fail "--check 应当报告投放自哪个 tag"

# ── 5. 换内容要覆盖；带前缀目录的 tarball 也要能解 ──────────────────────────
make_tarball aarch64-apple-darwin 'fake-darwin-v2' 'wist-approve-9-prefixed'
run "换内容投放" --from "${SRC}" --tag "${TAG}"
grep -q 'fake-darwin-v2' "${STATE}/aarch64-apple-darwin/wist-approve" ||
  fail "内容变了应当覆盖（带前缀目录的 tarball 也要能解开）"

# ── 6. 投放版本与当前 tag 不一致时要说出来（不是靠人记）─────────────────────
run "check（tag 不一致）" --check --tag v10.0.0-alpha
grep -q '需要重新投放' "${TMP}/out" || fail "tag 与制品不一致时 --check 应当提醒"

# ── 7. 下载 URL 的形状：<base>/<tag>/wist-approve-<tag>-<triple>.tar.gz ────────────
# 不能用真实的 GitHub / COS 地址（测试不能依赖外网）。`file://` 立刻失败、行为确定，
# 而失败信息里会带出脚本拼的那个 URL —— 这才是要钉住的东西：基址已包含仓库 + 渠道前缀，
# 后面只接 <tag>/<文件名>，**不能再**拼一层仓库名或 `releases/download`。
if APPROVER_ARTIFACT_BASE="file://${TMP}/nope" "${SCRIPT}" --tag "${TAG}" \
     >"${TMP}/out" 2>&1; then
  fail "制品源不可达时应当失败，而不是静静退出 0"
fi
for platform in "${EXPECTED_PLATFORMS[@]}"; do
  grep -q "file://${TMP}/nope/${TAG}/wist-approve-${TAG}-${platform}.tar.gz" "${TMP}/out" || {
    fail "下载 URL 形状不对（期望 <base>/${TAG}/wist-approve-${TAG}-${platform}.tar.gz）"
  }
done

echo "ok: wist-approve 投放脚本（triple 白名单 / 幂等 / 前缀 tarball / 部分失败不记版本 / URL 形状）"
