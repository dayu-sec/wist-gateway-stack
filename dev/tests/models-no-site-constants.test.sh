#!/usr/bin/env bash
# 门禁：数据面模型里**不许出现站点常量**，租户身份只能来自 sink 标签。
#
# 事故背景（2026-11-01）：
#   栈种子的 29 份 OML 里都手写了一行 `tenant_id = chars(<某个 19 位数字>);` ——
#   那是某个站点的业务身份，被当成常量烘进了**共享**模型。后果比「多一个字段」严重：
#     · 每条记录（facts / metrics / dsnap / ivsrep / 登录 / 审计 …）都被钉成那个租户，
#       现场绑定别的客户之后身份照样是错的（历史 metrics 里躺着 8 万多条错记录）；
#     · 真正的租户来源是 **sink 标签**（`topology/sinks/defaults.toml` 的
#       `tenant_id:${WIST_TENANT_ID:...}`，由 gwlinkd 写 `WIST_TENANT_ID`）——
#       模型里再硬写一份只会把它盖掉，而且**升级时看不出来**（运行根是 `cp -an`，不覆盖）。
#
# 钉两件事 —— 第二条是第一条的另一半，只删不补等于把租户彻底弄丢：
#   1. `sys/data-plane/models/**/*.oml` 里不许有 `tenant_id = chars(<数字>)`，
#      也不许有别的「长数字常量」赋值（站点 id / 实例 id 都长这样）；
#   2. `sys/data-plane/topology/sinks/defaults.toml` 必须仍然注入 `tenant_id:` 标签
#      —— 模型里那份删掉之后，这是唯一的租户来源。
#
#   dev/tests/models-no-site-constants.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
MODELS="${STACK_ROOT}/sys/data-plane/models"
DEFAULTS="${STACK_ROOT}/sys/data-plane/topology/sinks/defaults.toml"

[[ -d "${MODELS}" ]] || { echo "找不到模型目录：${MODELS}" >&2; exit 1; }
[[ -f "${DEFAULTS}" ]] || { echo "找不到 sink 默认值：${DEFAULTS}" >&2; exit 1; }

fail=0
bad() { echo "  [FAIL] $1" >&2; fail=1; }
ok() { echo "  [OK]   $1"; }

echo "== 1) 模型里不许有硬编码的租户常量（tenant_id = chars(<数字>)）=="
# `chars(...)` 是「写死一个字符串」的意思。`tenant_id` 只允许 `read(tenant_id)`
# 或干脆不写（由 sink 标签注入）。
hits="$(grep -rnE '^[[:space:]]*tenant_id[[:space:]]*=[[:space:]]*chars\(' "${MODELS}" || true)"
if [[ -n "${hits}" ]]; then
  bad "模型里写死了 tenant_id（应从 sink 标签来，或被 read(tenant_id) 读出来）："
  echo "${hits}" | sed 's/^/        /' >&2
else
  ok "没有写死的 tenant_id"
fi

echo "== 2) 模型里不许有长数字常量（站点 id / 实例 id 都长这样）=="
# 8 位以上纯数字当字符串常量 —— 现场合法的长数字常量目前一个都没有；
# 真需要时请改成参数（sink 标签 / vars），不要烘进共享模型。
hits="$(grep -rnE '=[[:space:]]*chars\([0-9]{8,}\)' "${MODELS}" || true)"
if [[ -n "${hits}" ]]; then
  bad "模型里出现长数字常量："
  echo "${hits}" | sed 's/^/        /' >&2
else
  ok "没有长数字常量"
fi

echo "== 3) 租户必须由 sink 标签注入（删掉模型里那份之后的唯一来源）=="
if grep -qE 'tenant_id:\$\{WIST_TENANT_ID' "${DEFAULTS}"; then
  ok "defaults.toml 仍注入 tenant_id:\${WIST_TENANT_ID...}"
else
  bad "defaults.toml 丢了 tenant_id 标签（模型里那份已删，租户会彻底没有）"
fi

echo "== 4) 模型里若写 tenant_id，只能是 read(...) =="
hits="$(grep -rnE '^[[:space:]]*tenant_id[[:space:]]*=[[:space:]]*(chars|read)\(' "${MODELS}" \
  | grep -vE '=[[:space:]]*read\(' || true)"
if [[ -n "${hits}" ]]; then
  bad "tenant_id 只要出现就必须是 read(...)："
  echo "${hits}" | sed 's/^/        /' >&2
else
  ok "tenant_id 的写法合规（未出现，或形如 read(...)）"
fi

echo
if [[ "${fail}" == "0" ]]; then
  echo "models no site constants test passed"
else
  echo "models no site constants test FAILED" >&2
  exit 1
fi
