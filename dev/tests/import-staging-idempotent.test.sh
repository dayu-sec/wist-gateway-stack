#!/usr/bin/env bash
# 门禁：包**已经在投放目录里**时，`import-package.sh` / `import-knowledge.sh` 必须照常走完。
#
# 为什么单列一条：2026-11-08 现场，`packages/` 里已经有 `wist-knowledge-0.9.3-alpha.tar.gz`，
# 再跑 `scripts/import-knowledge.sh packages/... --set` 时脚本**一声不响地退出**——
# 源和目标指向同一个文件，BSD/GNU 的 `cp` 返回 1（"are identical, not copied"），
# `set -e` 直接把脚本干掉，一次 API 都没发出去。用户看到的是「命令跑完但什么都没发生」。
# 所以这里钉住两件事：
#   * 源在投放目录里 → 不 cp、不失败，继续往下走（打印「已在投放目录」）；
#   * 源在别处 → 照常拷进投放目录（别为了修上面那条把正常路径也跳过）。
#
# 跑法：`dev/tests/import-staging-idempotent.test.sh`
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
IMPORT_PACKAGE="${STACK_ROOT}/scripts/import-package.sh"
IMPORT_KNOWLEDGE="${STACK_ROOT}/scripts/import-knowledge.sh"

for script in "${IMPORT_PACKAGE}" "${IMPORT_KNOWLEDGE}"; do
  [[ -f "${script}" ]] || { echo "missing script: ${script}" >&2; exit 1; }
done

TMP="$(mktemp -d)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM

PKG_DIR="${TMP}/packages"
SRC_DIR="${TMP}/src"
mkdir -p "${PKG_DIR}" "${SRC_DIR}"

run() {
  local label="$1"
  shift
  if ! "$@" >"${TMP}/out" 2>&1; then
    echo "FAIL ${label}：脚本失败了（源在投放目录里不该失败）" >&2
    cat "${TMP}/out" >&2
    exit 1
  fi
}

# ── import-package.sh ────────────────────────────────────────────────────────
AGENTD_NAME="wist-agentd-v0.28.1-alpha-aarch64-apple-darwin.tar.gz"
: >"${PKG_DIR}/${AGENTD_NAME}"

run "import-package（源已在 packages/）" \
  env PACKAGE_DIR="${PKG_DIR}" "${IMPORT_PACKAGE}" "${PKG_DIR}/${AGENTD_NAME}"
grep -q '已在投放目录' "${TMP}/out" || {
  echo "FAIL import-package：源已在投放目录时应当明说，而不是当作新拷入" >&2
  cat "${TMP}/out" >&2
  exit 1
}

# 源在别处：照常拷进来。
: >"${SRC_DIR}/${AGENTD_NAME}"
run "import-package（源在别处）" \
  env PACKAGE_DIR="${PKG_DIR}" "${IMPORT_PACKAGE}" "${SRC_DIR}/${AGENTD_NAME}"
grep -q '已导入' "${TMP}/out" || {
  echo "FAIL import-package：源在别处时应当拷进投放目录" >&2
  cat "${TMP}/out" >&2
  exit 1
}
[[ -f "${PKG_DIR}/${AGENTD_NAME}" ]] || {
  echo "FAIL import-package：投放目录里没有目标文件" >&2
  exit 1
}

# ── import-knowledge.sh ──────────────────────────────────────────────────────
KNOWLEDGE_NAME="wist-knowledge-9.9.9-alpha.tar.gz"
: >"${PKG_DIR}/${KNOWLEDGE_NAME}"
: >"${PKG_DIR}/${KNOWLEDGE_NAME}.sig"

run "import-knowledge（源已在 packages/，含 .sig）" \
  env PACKAGE_DIR="${PKG_DIR}" "${IMPORT_KNOWLEDGE}" "${PKG_DIR}/${KNOWLEDGE_NAME}"
grep -q '已在投放目录' "${TMP}/out" || {
  echo "FAIL import-knowledge：源已在投放目录时应当明说" >&2
  cat "${TMP}/out" >&2
  exit 1
}
grep -q '已在投放目录.*\.sig' "${TMP}/out" || {
  echo "FAIL import-knowledge：签名旁文件同样要跳过（不是只跳 tarball）" >&2
  cat "${TMP}/out" >&2
  exit 1
}

# 源在别处：tarball 与 .sig 都要落到投放目录。
: >"${SRC_DIR}/${KNOWLEDGE_NAME}"
: >"${SRC_DIR}/${KNOWLEDGE_NAME}.sig"
run "import-knowledge（源在别处）" \
  env PACKAGE_DIR="${PKG_DIR}" "${IMPORT_KNOWLEDGE}" "${SRC_DIR}/${KNOWLEDGE_NAME}"
[[ -f "${PKG_DIR}/${KNOWLEDGE_NAME}" && -f "${PKG_DIR}/${KNOWLEDGE_NAME}.sig" ]] || {
  echo "FAIL import-knowledge：tarball 或 .sig 没拷进投放目录" >&2
  cat "${TMP}/out" >&2
  exit 1
}

echo "ok: 源已在投放目录时两个导入脚本都照常走完，源在别处时照常拷入"
