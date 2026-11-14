#!/usr/bin/env bash
# 云资产采集（wist-harvest，**常驻服务**）：备料渲染值 + 建运行态目录。
#
# TOML 内容不在这里 —— 归 `sys/configs/harvest/*.tpl`（`gx.tpl` 渲染，见
# `sys/workflows/operators.gxl` ⑤b）。条件渲染用 handlebars 的 `{{#if harvest_enabled}}`：
# 本地硬关时数据源渲染成「只有注释」的合法 TOML，`diagnose` 会当场 FAIL。
# 「开不开」默认由中心决定（`[control]` 轮询网关的 `harvest.enabled`），这里只决定
# **允不允许调度**（`HARVEST_ENABLED`）与数据源长什么样。
#
# 为什么还需要这个脚本（GXL 干不了的三件事）：
#   1. `harvest-run/{spool,state}` 必须在 `gops sys perms --apply` **之前**存在，
#      否则 docker 会把 bind 源建成 root:root，容器（999）写不动；
#   2. 渲染值里有**派生值**（`regions` 的 TOML 字面量）与校验（非法地域直接失败）；
#   3. GXL 字符串**不还原 `\"`**（Ubuntu 的 /bin/sh 是 dash，printf 会把反斜杠写进 JSON，
#      于是 `gx.tpl` 报 `parse json data file`）—— JSON 由脚本写，别在 GXL 里拼。
#
# 产物：
#   configs/harvest/harvest.value.json   gx.tpl 的渲染值（含 harvest_enabled 布尔）
#   harvest-run/{spool,state}/           运行态（bind 源，必须早于 perms）
set -euo pipefail

DIR="${1:-configs/harvest}"
RUN_DIR="${HARVEST_RUN_DIR:-./harvest-run}"

enabled="${HARVEST_ENABLED:-false}"
case "${enabled}" in
  true | false) ;;
  *)
    echo "错误：HARVEST_ENABLED 只接受 true / false：'${enabled}'" >&2
    exit 1
    ;;
esac

code="${HARVEST_SOURCE_CODE:-tencent-cloud-prod}"
envr="${HARVEST_ENV_REF:-prod}"
regions="${HARVEST_REGIONS:-auto}"
control_url="${HARVEST_CONTROL_URL:-}"
control_poll_ms="${HARVEST_CONTROL_POLL_MS:-30000}"

case "${code}" in
  *[!A-Za-z0-9._:-]*)
    echo "错误：HARVEST_SOURCE_CODE 含非法字符：'${code}'（只允许 [A-Za-z0-9._:-]）" >&2
    exit 1
    ;;
esac

# 地域：`auto` 原样；逗号分隔的固定列表转成 TOML 数组字面量（模板里用三花括号原样输出）。
if [[ "${regions}" == "auto" ]]; then
  regions_literal='"auto"'
else
  list=""
  IFS=',' read -r -a parts <<<"${regions}"
  for p in "${parts[@]}"; do
    p="$(echo "${p}" | tr -d '[:space:]')"
    [[ -n "${p}" ]] || continue
    case "${p}" in
      *[!A-Za-z0-9-]*)
        echo "错误：HARVEST_REGIONS 里的地域名含非法字符：'${p}'" >&2
        exit 1
        ;;
    esac
    [[ -z "${list}" ]] && list="\"${p}\"" || list="${list}, \"${p}\""
  done
  [[ -n "${list}" ]] || {
    echo "错误：HARVEST_REGIONS 既不是 auto 也没有有效地域：'${regions}'" >&2
    exit 1
  }
  regions_literal="[${list}]"
fi
# 带引号的字面量写进 JSON 值时要按 JSON 规则转义（模板用三花括号原样输出）。
regions_json="${regions_literal//\"/\\\"}"

# ⓿ 宿主运行态目录（早于 perms 对齐，见文件头）
mkdir -p "${RUN_DIR}/spool" "${RUN_DIR}/state"
echo "  已确保运行态目录：${RUN_DIR}/{spool,state}"

# ① 渲染值
mkdir -p "${DIR}/sources.d"
# 旧版本按 `${source_code}.toml` 命名；现在固定 `source.toml`（gx.tpl 的 dst 不认变量）。
# 残留的旧文件名不会被 compose 引用，但仍留在目录里容易让人以为它在生效 —— 清掉。
legacy="${DIR}/sources.d/${code}.toml"
if [[ "${legacy}" != "${DIR}/sources.d/source.toml" ]] && [[ -f "${legacy}" ]]; then
  rm -f "${legacy}"
  echo "  已清理旧文件名：${legacy}（现在固定 source.toml）"
fi
VALUE_JSON="${DIR}/harvest.value.json"
tmp="$(mktemp "${VALUE_JSON}.XXXXXX")"
cat >"${tmp}" <<JSON
{
  "harvest_enabled": ${enabled},
  "harvest_source_code": "${code}",
  "harvest_env_ref": "${envr}",
  "harvest_regions_literal": "${regions_json}",
  "harvest_control_url": "${control_url}",
  "harvest_control_poll_ms": ${control_poll_ms}
}
JSON
if [[ -f "${VALUE_JSON}" ]] && cmp -s "${tmp}" "${VALUE_JSON}"; then
  rm -f "${tmp}"
  echo "  渲染值与当前一致，跳过：${VALUE_JSON}"
else
  chmod 644 "${tmp}"
  mv -f "${tmp}" "${VALUE_JSON}"
  echo "  已写：${VALUE_JSON}"
fi

# ② 启用状态说明（非阻断）
if [[ "${enabled}" == "true" ]]; then
  echo "  本地已允许调度：source_code=${code} env_ref=${envr} regions=${regions}"
  if [[ -n "${control_url}" ]]; then
    echo "  开关以中心为准：${control_url}（每 ${control_poll_ms}ms 一拍，新装默认关）"
  else
    echo "  未配 HARVEST_CONTROL_URL：开关只看本地 enabled，下次定点就会真采"
  fi
else
  echo "  本地硬关（HARVEST_ENABLED=false）：进程常驻但不调度，数据源会渲染成只有注释。"
  echo "  恢复：values/ 里写 harvest_enabled: true，再跑 gops sys localize。"
fi

# ③ 密钥：与网关共用 `.wist/sec-value.yml`（`gops sec` 维护，`:ro` 挂到容器 /secrets）。
#    只做**非阻断**提示 —— 缺键时容器起来会因 healthcheck 失败暴露，不必在 localize 阶段拦住。
if [[ -f ./.wist/sec-value.yml ]]; then
  echo "  密钥文件就绪：./.wist/sec-value.yml（需要键 toc_secretid / toc_secretkey，gops sec list 可核对）"
else
  echo "  提示：./.wist/sec-value.yml 不存在 —— 启用云采集前必须写入："
  echo "         toc_secretid / toc_secretkey（用 gops sec 维护，模式 0640、属组=容器 gid）"
fi
