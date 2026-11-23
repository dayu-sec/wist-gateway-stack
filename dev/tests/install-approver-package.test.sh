#!/usr/bin/env bash
# 门禁：审批终端安装包的**登记脚本**（`scripts/install-approver-package.sh`）。
#
# 这个脚本决定「网关能不能把 wist-approve 发给审批人」。它写错时不会报错，只会表现为
# 审批人装不上（503）。钉住四件事：
#
#   1. **平台表**必须正好是网关分发白名单那三个（musl 静态 ×2 + macOS arm64）；
#   2. **登记形状**：每个平台一条 POST，`source` 是**容器内路径** `/packages/<文件名>`
#      （网关读不到宿主路径 —— 这是最容易写错的一处）；
#   3. **制品源基址**已含仓库+渠道，地址 = `<基址>/<tag>/<文件名>`；
#   4. dry-run **不碰网络、不拷文件**：只打印将执行的请求。
#
# 跑法：`dev/tests/install-approver-package.test.sh`（CI 由 scripts.yml 全量跑）
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
SCRIPT="${STACK_ROOT}/scripts/install-approver-package.sh"
[[ -f "${SCRIPT}" ]] || { echo "missing script: ${SCRIPT}" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM

TAG="v9.9.9-alpha"
EXPECTED_PLATFORMS=(aarch64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl)
fail() { echo "FAIL $*" >&2; exit 1; }

# ── 1. 平台表 ────────────────────────────────────────────────────────────────
declared="$(sed -n 's/^PLATFORMS=(\(.*\))$/\1/p' "${SCRIPT}")"
[[ -n "${declared}" ]] || fail "脚本里没有 PLATFORMS 数组"
for platform in "${EXPECTED_PLATFORMS[@]}"; do
  case " ${declared} " in
    *" ${platform} "*) ;;
    *) fail "PLATFORMS 缺 ${platform}（现为：${declared}）" ;;
  esac
done
for platform in ${declared}; do
  case " ${EXPECTED_PLATFORMS[*]} " in
    *" ${platform} "*) ;;
    *) fail "PLATFORMS 里有白名单外的 ${platform}（网关不会分发它）" ;;
  esac
done
case "${declared}" in
  *gnu*) fail "Linux 制品必须是 musl（gnu 在客户老系统上跑不起来）" ;;
esac

BASE_ENV=(GATEWAY_URL=https://gw.example ADMIN_TOKEN=t "PACKAGE_DIR=${TMP}/packages")

# ── 2. dry-run（--from）：三条 POST，source 是容器内路径，且不拷文件 ─────────
mkdir -p "${TMP}/src"
for platform in "${EXPECTED_PLATFORMS[@]}"; do
  printf 'fake' >"${TMP}/payload"
  tar -czf "${TMP}/src/wist-approve-${TAG}-${platform}.tar.gz" -C "${TMP}" payload
done
env "${BASE_ENV[@]}" bash "${SCRIPT}" --from "${TMP}/src" --tag "${TAG}" --dry-run >"${TMP}/out" 2>&1 ||
  { cat "${TMP}/out" >&2; fail "--from --dry-run 应当成功"; }
for platform in "${EXPECTED_PLATFORMS[@]}"; do
  grep -q "POST https://gw.example/api/v1/admin/approver/install-package .*\"platform\":\"${platform}\".*\"source\":\"/packages/wist-approve-${TAG}-${platform}.tar.gz\"" "${TMP}/out" ||
    { cat "${TMP}/out" >&2; fail "${platform} 的登记请求形状不对（source 必须是 /packages/<文件名>）"; }
done
[[ -z "$(ls -A "${TMP}/packages" 2>/dev/null)" ]] || fail "dry-run 不应把文件拷进投放目录"

# ── 3. dry-run（--tag）：不碰网络，但要把下载 URL 打出来 ────────────────────
env "${BASE_ENV[@]}" bash "${SCRIPT}" --tag "${TAG}" --dry-run >"${TMP}/out" 2>&1 ||
  { cat "${TMP}/out" >&2; fail "--tag --dry-run 应当成功（且不需要网络）"; }
for platform in "${EXPECTED_PLATFORMS[@]}"; do
  grep -q "https://github.com/dayu-sec/wist-approve/releases/download/${TAG}/wist-approve-${TAG}-${platform}.tar.gz" "${TMP}/out" ||
    { cat "${TMP}/out" >&2; fail "下载 URL 形状不对：<基址>/<tag>/wist-approve-<tag>-<triple>.tar.gz"; }
done

# ── 4. 缺平台 / 没给来源 / --check 缺地址 ───────────────────────────────────
rm -rf "${TMP}/partial" && mkdir -p "${TMP}/partial"
cp "${TMP}/src/wist-approve-${TAG}-aarch64-apple-darwin.tar.gz" "${TMP}/partial/"
if env "${BASE_ENV[@]}" bash "${SCRIPT}" --from "${TMP}/partial" --tag "${TAG}" --dry-run >"${TMP}/out" 2>&1; then
  fail "少平台时应当非零退出"
fi
grep -q '未能登记' "${TMP}/out" || fail "少平台时应当汇总说明"

if env -u TAG bash -c "GATEWAY_URL= ADMIN_TOKEN=t bash '${SCRIPT}'" >"${TMP}/out" 2>&1; then
  fail "既没有 --tag 也没有 --from 时应当失败"
fi

if env -u GATEWAY_URL ADMIN_TOKEN=t WIST_GATEWAY_VALUE_JSON="${TMP}/nope.json" bash -c "cd '${TMP}' && bash '${SCRIPT}' --check" >"${TMP}/out" 2>&1; then
  fail "--check 缺管理面地址时应当失败"
fi
grep -q 'GATEWAY_URL' "${TMP}/out" || fail "--check 缺地址时应当说清要什么"

echo "ok: 审批终端安装包登记脚本（平台表 / 容器内路径 / 源基址 / dry-run 不落盘）"
