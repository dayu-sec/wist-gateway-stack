#!/usr/bin/env bash
# `scripts/install-initial-knowledge.sh` 的回归测试：钉住「不静默」这条行为契约。
#
# 为什么单测它：这个脚本是 localize 里**唯一**决定网关有没有内容的环节。它若静默跳过，
# 装出来的网关会「看起来装好了、实际空载」——不产用途建议、也派不出采集工作，很难从现象反查
# （`wist-gateway/docs/design/knowledge-content-management.md` §2.3 记过这个坑）。
# 所以这里钉三件事：空 URL 要告警、下载没落盘要**失败**、包在就正常就位。
#
# 纯文件系统逻辑，不依赖 docker / 网络：
#   dev/tests/install-initial-knowledge.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
SCRIPT="${STACK_ROOT}/scripts/install-initial-knowledge.sh"
[[ -f "${SCRIPT}" ]] || { echo "找不到 ${SCRIPT}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# 脚本按**自身位置**推 STACK_ROOT，所以拷进一份临时栈树里跑，绝不碰真实栈。
mkdir -p "${TMP}/site/scripts" "${TMP}/site/packages" "${TMP}/site/configs/gateway"
cp "${SCRIPT}" "${TMP}/site/scripts/"
RUN="${TMP}/site/scripts/install-initial-knowledge.sh"
PKG_NAME="wist-knowledge-9.9.9-test.tar.gz"
DEST="${TMP}/site/configs/gateway/knowledge/initial"

set +e
fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "  [OK]   $1"; else echo "  [FAIL] $1（期望 $2，实际 $3）"; fail=1; fi; }
has() { case "$2" in *"$1"*) echo "  [OK]   $3" ;; *) echo "  [FAIL] $3：$2"; fail=1 ;; esac; }

echo "== 1) KNOWLEDGE_PKG_URL 为空 → 跳过但**显式告警**（exit 0）=="
out="$(cd "${TMP}/site" && env -u KNOWLEDGE_PKG_URL bash "${RUN}" 2>&1)"; rc=$?
chk "空 URL 不阻断 localize（exit 0）" "0" "${rc}"
has "空载" "${out}" "告警说清了后果（网关将空载）"

echo "== 2) URL 有但包没落盘 → **失败**并给出处置 =="
out="$(cd "${TMP}/site" && KNOWLEDGE_PKG_URL="https://example.invalid/${PKG_NAME}" bash "${RUN}" 2>&1)"; rc=$?
chk "缺包时 exit 1（不装出一个空网关）" "1" "${rc}"
has "不可达" "${out}" "报错点明了可能原因（不可达）"
has "${PKG_NAME}" "${out}" "报错给出了包名，便于手工放包"

echo "== 3) 包在 → 解开到 source_dir，五份齐全（剥掉顶层目录）=="
STAGE="${TMP}/stage/wist-knowledge-9.9.9-test"
mkdir -p "${STAGE}"
for f in catalog.toml packs.toml templates.toml purpose-rules.toml aspect-policies.toml; do
  printf 'x = 1\n' > "${STAGE}/${f}"
done
printf '{}\n' > "${STAGE}/manifest.json"
tar -czf "${TMP}/site/packages/${PKG_NAME}" -C "${TMP}/stage" wist-knowledge-9.9.9-test
out="$(cd "${TMP}/site" && KNOWLEDGE_PKG_URL="https://example.invalid/${PKG_NAME}" bash "${RUN}" 2>&1)"; rc=$?
chk "包在时 exit 0" "0" "${rc}"
missing=""
for f in catalog.toml packs.toml templates.toml purpose-rules.toml aspect-policies.toml; do
  [[ -f "${DEST}/${f}" ]] || missing="${missing} ${f}"
done
chk "五份数据都就位" "" "${missing}"

echo
if [[ "${fail}" == "0" ]]; then echo "全部通过"; else echo "存在失败项"; exit 1; fi
