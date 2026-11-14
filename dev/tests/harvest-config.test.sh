#!/usr/bin/env bash
# 云资产采集（harvest）配置：备料 → gx.tpl 渲染 → compose 接线。
#
#   dev/tests/harvest-config.test.sh
#
# 钉八件事（都是现场会踩的）：
#   1. 未启用时**不渲染可用数据源**（整份只有注释）——「绕过 profile 硬起容器」必须当场失败；
#   2. 启用后数据源必须带 `vendor`（缺了 harvest 直接解析失败，不会猜厂商）；
#   3. 地域字面量：`auto` 原样、逗号列表转 TOML 数组；
#   4. 非法 HARVEST_ENABLED / 非法地域直接失败，不写出半成品；
#   5. `harvest.toml` 的 sink 指向同栈统一入口 `wparse:9000`（与 agentd 同一口，靠 WPL 标记区分）；
#   6. compose：**常驻**（没有 profiles）、没有宿主端口、`--source` 指向固定的 `source.toml`；
#   7. 站点默认值（`sys/setting/vars.yml`）把开关交给中心：本地 `enabled=true` 只是允许调度，
#      真正的开/关是 `HARVEST_CONTROL_URL` 轮询到的那一项；
#   8. 入口契约：`tcp_1` 的端口 / framing / ndjson / 读实例数与 harvest 的 sink 对得上
#      （换掉 tcp_1 就会静默断流）。
set -uo pipefail

S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

OUT="${TMP}/out"
VALUE_JSON="${OUT}/harvest.value.json"
SOURCE_TOML="${OUT}/sources.d/source.toml"
SERVICE_TOML="${OUT}/harvest.toml"
COMPOSE="${S}/sys/docker-compose.yml"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }

# 备料：子 shell 传变量，不泄漏到下一条用例。
prep() { # prep <VAR=VAL>...
  (
    for kv in "$@"; do
      export "${kv%%=*}=${kv#*=}"
    done
    export HARVEST_RUN_DIR="${TMP}/run"
    cd "${S}" && ./scripts/init-harvest.sh "${OUT}"
  ) >"${TMP}/prep.log" 2>&1
}

jraw() {
  python3 - "${VALUE_JSON}" "$1" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps(data[sys.argv[2]], ensure_ascii=False))
PY
}

jstr() {
  python3 - "${VALUE_JSON}" "$1" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data[sys.argv[2]])
PY
}

GXL="${TMP}/render.gxl"
cat >"${GXL}" <<GXL
mod tpls {
  flow render {
    gx.tpl ( tpl: "./sys/configs/harvest/harvest.toml.tpl", dst: "${OUT}/harvest.toml", file: "${OUT}/harvest.value.json" );
    gx.tpl ( tpl: "./sys/configs/harvest/sources.d/source.toml.tpl", dst: "${OUT}/sources.d/source.toml", file: "${OUT}/harvest.value.json" );
  }
}

mod envs  {
  #[usage(desp="default", color="green")]
  env default     {}
}

mod main : tpls {
}
GXL

render_tpls() {
  command -v gx >/dev/null 2>&1 || return 2
  (cd "${S}" && gx run -c "${GXL}" render >/dev/null 2>&1)
}

echo "① 默认：采集不启用"
if prep; then ok "备料成功"; else no "备料失败：$(tail -3 "${TMP}/prep.log")"; fi
if [ "$(jraw harvest_enabled)" = "false" ]; then ok "harvest_enabled=false"; else no "harvest_enabled 不是 false"; fi
if [ -d "${TMP}/run/spool" ] && [ -d "${TMP}/run/state" ]; then
  ok "bind 源目录在备料时建好（早于 perms）"
else
  no "bind 源目录没建出来（docker 会建成 root:root）"
fi

render_tpls
render_rc=$?
if [ "${render_rc}" -eq 2 ]; then
  echo "  skip 未安装 gx：跳过模板渲染断言"
else
  [ "${render_rc}" -eq 0 ] || no "gx tpl 渲染失败（见 ${GXL}）"
  if grep -qE '^source_code' "${SOURCE_TOML}" 2>/dev/null; then
    no "未启用时渲染出了可用的数据源"
  else
    ok "未启用时数据源只有注释"
  fi
  if grep -q '采集未启用' "${SOURCE_TOML}" 2>/dev/null; then
    ok "渲染产物写明了启用步骤"
  else
    no "渲染产物没有说明为什么没启用"
  fi
  if grep -qE '^enabled = false$' "${SERVICE_TOML}" 2>/dev/null; then
    ok "harvest.toml 里 enabled = false（进程常驻但不调度）"
  else
    no "harvest.toml 的 enabled 不是 false"
  fi
fi

echo "② 启用：数据源字段齐、sink 指向同栈 wparse"
if prep HARVEST_ENABLED=true; then ok "备料成功（启用态）"; else no "备料失败（启用态）"; fi
if [ "$(jraw harvest_enabled)" = "true" ]; then ok "harvest_enabled=true"; else no "harvest_enabled 不是 true"; fi
if [ "$(jstr harvest_regions_literal)" = '"auto"' ]; then ok "地域默认 auto"; else no "地域默认不是 auto"; fi

render_tpls
render_rc=$?
if [ "${render_rc}" -eq 2 ]; then
  echo "  skip 未安装 gx：跳过模板渲染断言"
elif [ "${render_rc}" -ne 0 ]; then
  no "gx tpl 渲染失败（启用态）"
else
  for line in \
    '^source_code = "tencent-cloud-prod"$' \
    '^vendor = "TENCENT_CLOUD"$' \
    '^group = "inventory"$' \
    '^env_ref = "prod"$' \
    '^regions = "auto"$' \
    '^secret_id = \{ file = "/secrets/sec-value.yml", field = "toc_secretid" \}$'; do
    if grep -qE "${line}" "${SOURCE_TOML}"; then
      ok "数据源里有 ${line}"
    else
      no "数据源里缺 ${line}"
    fi
  done
  if grep -qE '^enabled = true$' "${SERVICE_TOML}"; then
    ok "harvest.toml 里 enabled = true"
  else
    no "harvest.toml 的 enabled 不是 true"
  fi
  if grep -qE '^\[control\]$' "${SERVICE_TOML}"; then
    ok "harvest.toml 有 [control] 段（中心配置轮询）"
  else
    no "harvest.toml 缺 [control] 段"
  fi
  if grep -qE '^url = ""$' "${SERVICE_TOML}"; then
    ok "control.url 默认空（未开中心轮询，行为与旧版一致）"
  else
    no "control.url 默认不是空"
  fi
  if grep -qE '^endpoint = "wparse:9000"$' "${SERVICE_TOML}"; then
    ok "harvest.toml 的 sink 指向 wparse:9000"
  else
    no "harvest.toml 的 sink 不是 wparse:9000"
  fi
  if [ -f "${S}/sys/data-plane/topology/sources/harvest_1.toml" ]; then
    no "还留着独立的 harvest_1 source（数据入口应统一到 tcp_1:9000）"
  else
    ok "没有额外的采集专用 source（统一走 tcp_1:9000）"
  fi
  leftovers="$(grep -oE '\{\{[^}]+\}\}' "${SERVICE_TOML}" "${SOURCE_TOML}" 2>/dev/null || true)"
  if [ -z "${leftovers}" ]; then
    ok "渲染产物里没有残留占位符"
  else
    no "渲染产物残留占位符：${leftovers}"
  fi
fi

echo "③ 地域列表：逗号分隔 → TOML 数组字面量"
prep HARVEST_ENABLED=true HARVEST_REGIONS="ap-guangzhou, ap-shanghai"
if [ "$(jstr harvest_regions_literal)" = '["ap-guangzhou", "ap-shanghai"]' ]; then
  ok "地域列表转成 TOML 数组"
else
  no "地域列表没转成预期字面量：$(jstr harvest_regions_literal)"
fi

echo "④ 配错就当场失败（不静默）"
if prep HARVEST_ENABLED=yes; then no "HARVEST_ENABLED=yes 竟然通过了"; else ok "非法 HARVEST_ENABLED 被拒绝"; fi
if prep HARVEST_ENABLED=true HARVEST_REGIONS=" , "; then
  no "空地域列表竟然通过了"
else
  ok "空地域列表被拒绝"
fi

echo "⑤ compose 接线"
block="$(awk -v svc="  harvest:" '
  $0 == svc { inside = 1; print; next }
  inside && /^  [A-Za-z0-9_-]+:$/ { inside = 0 }
  inside { print }
' "${COMPOSE}")"
if printf '%s' "${block}" | grep -qE '^\s+profiles:'; then
  no "harvest 段还在用 profiles（应当是常驻 + enabled 开关）"
else
  ok "harvest 常驻（没有 profiles，开关走 enabled）"
fi
if printf '%s' "${block}" | grep -qE '^\s+- "?[0-9.:]+:[0-9]+'; then
  no "harvest 段暴露了宿主端口"
else
  ok "harvest 没有宿主端口"
fi
if printf '%s' "${block}" | grep -q '/etc/wist-harvest/sources.d/source.toml'; then
  ok "--source 指向固定的 source.toml"
else
  no "--source 没指向 source.toml"
fi

echo "⑥ 站点默认值：开关在中心（页面）"
VARS="${S}/sys/setting/vars.yml"
vval() { awk -v key="  - name: $1" '$0 == key { getline; sub(/^[[:space:]]+value: /, ""); gsub(/^"|"$/, ""); print; exit }' "${VARS}"; }
[ "$(vval HARVEST_ENABLED)" = "true" ] \
  && ok "HARVEST_ENABLED 默认 true（允许调度，不是安装期就采）" \
  || no "HARVEST_ENABLED 默认不是 true（页面开关会失效）"
case "$(vval HARVEST_CONTROL_URL)" in
  *gateway:3001/api/v1/harvest/control*) ok "control.url 默认指向同栈网关" ;;
  *) no "control.url 没指向 http://gateway:3001/api/v1/harvest/control" ;;
esac
if grep -q 'HARVEST_TENANT_ID' "${VARS}"; then
  no "vars.yml 里还有 HARVEST_TENANT_ID（采集器不感知租户）"
else
  ok "vars.yml 里没有 tenant 残留"
fi

echo "⑦ 统一入口契约：tcp_1 与 harvest 的 sink 必须同口同帧"
TCP1="${S}/sys/data-plane/topology/sources/tcp_1.toml"
for line in '^port = 9000$' '^framing = "len"$' '^data_format = "ndjson"$'; do
  if grep -qE "${line}" "${TCP1}" 2>/dev/null; then
    ok "tcp_1 有 ${line}"
  else
    no "tcp_1 缺 ${line}（采集与 agentd 共用这个入口）"
  fi
done
# 两个生产者共用一条 source：读实例必须 >=2，否则会被对方的半帧占住。
if grep -qE '^instances = [2-9]$' "${TCP1}" 2>/dev/null; then
  ok "tcp_1 的读实例 >=2（采集不会阻塞 agent 上送）"
else
  no "tcp_1 只开了一个读实例（harvest 大帧会阻塞 agent 上送）"
fi
if grep -qE '^endpoint = "wparse:9000"$' "${SERVICE_TOML}" 2>/dev/null; then
  ok "harvest 的 endpoint 与 tcp_1 同端口"
else
  no "harvest 的 endpoint 与 tcp_1 不一致（或没渲染）"
fi

printf '\n通过 %d，失败 %d\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
