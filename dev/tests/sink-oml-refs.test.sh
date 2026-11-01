#!/usr/bin/env bash
# 门禁：sink 分组引用的 OML 名必须**真的存在**（或含通配）。
#
# 为什么单列一条：引用了不存在的 OML 名**不会报错** ——
#   引擎照常装载（`load sink route confs` 通过、进程正常出数），只是那个分组**永远收不到记录**，
#   记录落到兜底分组（`oml = ["*"]` 的 gateway-logs）或直接丢。2026-11-01 就踩过：
#   `business.d/ignore.toml` 写 `oml = ["host/ignore"]`，而 wp-rules 从 v1.0.24-alpha 起把
#   主机审计规则改名成 `kernel_system_host/*` —— 被忽略的审计噪声全部改投兜底 sink，
#   页面 / 告警上完全看不出是这里错了。
#
# 钉的规则：
#   1. 不含通配的名字 → 必须存在同名 OML（`name : <名字>`）；
#   2. 含 `*` 的名字 → 至少要匹配到一个现有 OML（否则同样是静默不命中）；
#   3. 顺手拦一个常见笔误：写成 `ignore`（少了目录前缀）。它匹配不到任何 OML，
#      想让「所有 ignore 规则」都进来就写 `*/ignore`。
#
#   dev/tests/sink-oml-refs.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
MODELS="${STACK_ROOT}/sys/data-plane/models/oml"
SINKS="${STACK_ROOT}/sys/data-plane/topology/sinks"

[[ -d "${MODELS}" ]] || { echo "找不到 OML 目录：${MODELS}" >&2; exit 1; }
[[ -d "${SINKS}" ]] || { echo "找不到 sink 目录：${SINKS}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# OML 名：每个 adm.oml 头部的 `name : <名字>`（不是文件名 —— 目录名与 OML 名可以不同）。
OML_LIST="${TMP}/oml-names.txt"
grep -rh '^name *: *' "${MODELS}" | sed 's/^name *: *//; s/[[:space:]]*$//' | sort -u > "${OML_LIST}"
oml_count="$(wc -l < "${OML_LIST}" | tr -d ' ')"
if [[ "${oml_count}" -eq 0 ]]; then
  echo "没有解析到任何 OML 名（models/oml 是空的？）" >&2
  exit 1
fi

# 名字是否存在（精确）／是否能被通配命中。
name_exists() {
  grep -Fxq "$1" "${OML_LIST}"
}
glob_hits() {
  local pattern="$1" oml hit=0
  while IFS= read -r oml; do
    # shellcheck disable=SC2053  # 这里就要 glob，不能加引号。
    if [[ "${oml}" == ${pattern} ]]; then hit=1; break; fi
  done < "${OML_LIST}"
  echo "${hit}"
}

fail=0
echo "OML 共 ${oml_count} 个；开始核对 sink 引用……"

for sink in "${SINKS}"/*/*.toml "${SINKS}"/*.toml; do
  [[ -f "${sink}" ]] || continue
  rel="${sink#"${STACK_ROOT}/"}"
  while IFS= read -r keyword; do
    # 取 `oml = ["a", "b"]` 里的每个引号内名字。
    names="$(printf '%s' "${keyword}" | sed 's/^[^=]*=//' | grep -o '"[^"]*"' | tr -d '"')"
    [[ -n "${names}" ]] || continue
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      if [[ "${name}" == *"*"* ]]; then
        if [[ "$(glob_hits "${name}")" == "1" ]]; then
          echo "  [OK]   ${rel}：'${name}' 能匹配到 OML"
        else
          echo "  [FAIL] ${rel}：通配引用 '${name}' 匹配不到任何 OML" >&2
          fail=1
        fi
      else
        if name_exists "${name}"; then
          echo "  [OK]   ${rel}：'${name}'"
        else
          echo "  [FAIL] ${rel}：引用 '${name}' 不存在（改名 / 漏前缀？全量收请写 '*/<名>'）" >&2
          fail=1
        fi
      fi
    done <<< "${names}"
  done < <(grep -hE '^oml *=' "${sink}" || true)
done

echo
if [[ "${fail}" == "0" ]]; then
  echo "sink oml refs test passed"
else
  echo "sink oml refs test FAILED" >&2
  exit 1
fi
