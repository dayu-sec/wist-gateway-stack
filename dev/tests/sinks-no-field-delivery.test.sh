#!/usr/bin/env bash
# 门禁：栈种子的 sink **不得向计算区数据场（wist-field）投递数据**。
#
# 为什么单列一条：种子（`sys/data-plane`）是**共享**的出厂配置，而客户号、field 主机名、
# field 端口只属于某个站点。种子一旦带上 field 投递：
#   * 新站点开箱就往**别的**站点的 field 写（跨租户污染，且现场看不出是谁发的）；
#   * 站点在自己的 infra 仓里删掉 sink 也删不掉种子里那份 —— 运行根是 `cp -an` 补种，
#     升级时不会覆盖，只能人肉去 work 目录里捞；
#   * 客户号写死在种子里，换客户就是死值 —— 与 2026-11-01 那次
#     `tenant_id = chars(<19 位客户号>)` 事故是同一类错误（见 `models-no-site-constants.test.sh`）。
#
# 边界（别做过头）：`connectors/sink.d/24-wist-field_sinks.toml` 里的 `wist-field-*`
# **连接器定义要留着** —— 那是「能力」。站点在自己的 infra 仓里写
# `connect = "wist-field-atlas"` 就能用，不必把报文格式抄一遍。被禁的是 sink **引用**它们
# （引用了 = 真的开始投递）。
#
#   dev/tests/sinks-no-field-delivery.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
DATA_PLANE="${STACK_ROOT}/sys/data-plane"
SINKS="${DATA_PLANE}/topology/sinks"
CONNECTORS="${DATA_PLANE}/connectors/sink.d"

[[ -d "${SINKS}" ]] || { echo "找不到 sink 目录：${SINKS}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# 把**生效行**抽出来：注释里写「不要往 field 投递」是说明，不是投递。
# 每行前面带上文件（相对栈根），命中时能直接定位。
EFFECTIVE="${TMP}/effective.txt"
: > "${EFFECTIVE}"
sink_count=0
while IFS= read -r sink; do
  sink_count=$((sink_count + 1))
  rel="${sink#"${STACK_ROOT}/"}"
  sed 's/[[:space:]]*#.*//' "${sink}" \
    | awk -v rel="${rel}" 'NF { print rel ": " $0 }' >> "${EFFECTIVE}"
done < <(find "${SINKS}" -name '*.toml' | sort)

if [[ "${sink_count}" -eq 0 ]]; then
  echo "没找到任何 sink 配置：${SINKS}（种子是空的？）" >&2
  exit 1
fi

fail=0
bad() { echo "  [FAIL] $1" >&2; fail=1; }
ok() { echo "  [OK]   $1"; }

check() {
  local label="$1" pattern="$2" hits
  if hits="$(grep -E -- "${pattern}" "${EFFECTIVE}")" && [[ -n "${hits}" ]]; then
    bad "${label}"
    printf '%s\n' "${hits}" | sed 's/^/        /' >&2
  else
    ok "${label}"
  fi
}

echo "== 1) 种子 sink（${sink_count} 份）里不许有 field 投递 =="

# 1. 引用 field 连接器 = 直接投递（最容易被顺手抄进来的形态）。
check "没引用 wist-field-* 连接器" 'connect[[:space:]]*=[[:space:]]*"wist-field-'

# 2. 手写端点变量 / 内部路径：即使不走连接器，同样是往 field 发。
check "没写 FIELD_{EVIDENCE,ATLAS,METRICS}_URL" 'FIELD_(EVIDENCE|ATLAS|METRICS)_URL'
check "没有 field 的内部端点路径（/internal/evidence|/internal/atlas）" 'internal/(evidence|atlas)'

# 3. 站点常量：端口 / 主机名 / 客户号 / atlas 租户 UUID。
#    field 侧固定用 6800（evidence）/6801（atlas）/6802（VM）。
check "没有 field 端口（:6800 / :6801 / :6802）" ':680[012]'
check "没有 field 主机名（field-*）" 'field-[a-z0-9]'
check "没有 19 位客户号" '(^|[^0-9])[0-9]{19}([^0-9]|$)'
check "没有 atlas 租户 UUID" '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

echo "== 2) 连接器定义仍在（能力留着，站点可直接复用）=="
FIELD_CONNECTORS="${CONNECTORS}/24-wist-field_sinks.toml"
if [[ ! -f "${FIELD_CONNECTORS}" ]]; then
  bad "缺连接器文件：${FIELD_CONNECTORS#"${STACK_ROOT}/"}（站点会退回手写端点，换地址必漏改）"
else
  for id in wist-field-evidence wist-field-atlas wist-field-metrics; do
    if grep -q "id = \"${id}\"" "${FIELD_CONNECTORS}"; then
      ok "连接器在位：${id}"
    else
      bad "连接器文件里缺 id = \"${id}\""
    fi
  done
fi

echo
if [[ "${fail}" == "0" ]]; then
  echo "sinks no field delivery test passed"
else
  echo "sinks no field delivery test FAILED" >&2
  echo "  说明：种子只负责「采集 + 落到本机 + 进本机 VM/网关」，对计算区（field）的投递属于站点 infra 仓。" >&2
  exit 1
fi
