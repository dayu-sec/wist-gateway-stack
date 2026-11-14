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
#   7. 站点默认值（`sys/setting/vars.yml`）把开关交给网关：本地 `enabled=true` 只是允许调度，
#      真正的开/关是网关下发的 standing；端点不写服务名（证书 SAN 是 WEB_DOMAIN）；
#      且 compose 必须给 gateway 加上这个域名的网络别名（否则验名一定失败）；
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
    # 网关端点默认由 WEB_DOMAIN 推导（与 `gops sys localize` 注入的同名变量一致）。
    export WEB_DOMAIN="${WEB_DOMAIN:-gw.example.com}"
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
RENDER_OK=0
if [ "${render_rc}" -eq 2 ]; then
  echo "  skip 未安装 gx：跳过模板渲染断言"
elif [ "${render_rc}" -ne 0 ]; then
  no "gx tpl 渲染失败（启用态）"
else
  RENDER_OK=1
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
  if grep -qE '^\[gateway\]$' "${SERVICE_TOML}"; then
    ok "harvest.toml 有 [gateway] 段（网关工作授权）"
  else
    no "harvest.toml 缺 [gateway] 段"
  fi
  if grep -qE '^endpoint = "https://gw\.example\.com:3000"$' "${SERVICE_TOML}"; then
    ok "gateway.endpoint 由 WEB_DOMAIN 推导（同名网络别名 + 容器内 3000）"
  else
    no "gateway.endpoint 不是 https://<WEB_DOMAIN>:3000：$(grep -E '^endpoint' "${SERVICE_TOML}" | head -1)"
  fi
  if grep -qE '^ca_file = "/etc/wist-harvest/gateway-ca.pem"$' "${SERVICE_TOML}"; then
    ok "gateway.ca_file 指向挂进来的网关 CA"
  else
    no "gateway.ca_file 没指向 /etc/wist-harvest/gateway-ca.pem"
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

# 采集是**可选服务**：未启用时不能让缺域名把整栈 localize 打死；启用时又必须当场拦住
# （否则会静默跑成离线模式、完全绕开网关授权）。
no_domain() { # no_domain <enabled>
  (
    cd "${S}" &&
      env -u WEB_DOMAIN -u HARVEST_GATEWAY_ENDPOINT \
        HARVEST_ENABLED="$1" HARVEST_RUN_DIR="${TMP}/run" \
        ./scripts/init-harvest.sh "${OUT}"
  ) >/dev/null 2>&1
}
if no_domain false; then
  ok "未启用 + 无 WEB_DOMAIN：只告警（可选服务不阻断 localize）"
else
  no "未启用 + 无 WEB_DOMAIN 竟然失败了（可选服务不该卡住整栈）"
fi
if no_domain true; then
  no "启用采集但没有域名竟然通过了（会静默跑成离线模式）"
else
  ok "启用采集但推不出端点：当场失败（不静默降级）"
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

# gateway 段：证书 SAN 里的域名必须能解析到这个容器，否则 harvest 验名必然失败。
gwblock="$(awk -v svc="  gateway:" '
  $0 == svc { inside = 1; print; next }
  inside && /^  [A-Za-z0-9_-]+:$/ { inside = 0 }
  inside { print }
' "${COMPOSE}")"
if printf '%s' "${gwblock}" | grep -qE '^\s+- \$\{WEB_DOMAIN\}$'; then
  ok "gateway 有 \${WEB_DOMAIN} 网络别名（内网可连、验的就是证书里的名字）"
else
  no "gateway 没有 \${WEB_DOMAIN} 网络别名（harvest 拿域名连会解析不到）"
fi

echo "⑥ 站点默认值：授权在网关（页面）"
VARS="${S}/sys/setting/vars.yml"
vval() { awk -v key="  - name: $1" '$0 == key { getline; sub(/^[[:space:]]+value: /, ""); gsub(/^"|"$/, ""); print; exit }' "${VARS}"; }
[ "$(vval HARVEST_ENABLED)" = "true" ] \
  && ok "HARVEST_ENABLED 默认 true（允许调度，不是安装期就采）" \
  || no "HARVEST_ENABLED 默认不是 true（页面授权会失效）"
case "$(vval HARVEST_GATEWAY_ENDPOINT)" in
  '') ok "gateway.endpoint 留空（同栈时由 WEB_DOMAIN 推导，不写服务名）" ;;
  https://*) ok "gateway.endpoint 显式指定了 https://..." ;;
  *) no "gateway.endpoint 既不是空也不是 https://..." ;;
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
if [ "${RENDER_OK}" -eq 0 ]; then
  echo "  skip 未安装 gx：跳过 endpoint 渲染断言"
elif grep -qE '^endpoint = "wparse:9000"$' "${SERVICE_TOML}" 2>/dev/null; then
  ok "harvest 的 endpoint 与 tcp_1 同端口"
else
  no "harvest 的 endpoint 与 tcp_1 不一致：$(grep -E '^endpoint' "${SERVICE_TOML}" 2>/dev/null || echo 渲染产物缺失)"
fi

echo "⑧ 采集器身份落在共享的 state_dir 里（bootstrap 换的证书 run 看得见、重建不丢）"
if [ "${RENDER_OK}" -eq 0 ]; then
  echo "  skip 未安装 gx：跳过渲染断言"
else
  state_dir="$(sed -n 's/^state_dir = "\(.*\)"$/\1/p' "${SERVICE_TOML}")"
  identity_dir="$(sed -n 's/^identity_dir = "\(.*\)"$/\1/p' "${SERVICE_TOML}")"
  if [ -z "${state_dir}" ] || [ -z "${identity_dir}" ]; then
    no "harvest.toml 缺 state_dir / identity_dir（身份会落到容器层，重建即丢）"
  else
    case "${identity_dir}" in
      "${state_dir%/}"/*) ok "identity_dir 在 state_dir 下：${identity_dir}" ;;
      *) no "identity_dir=${identity_dir} 不在 state_dir=${state_dir} 下" ;;
    esac
  fi
fi
# 两边都得挂同一个 state 目录：bootstrap 写、run 读（不挂就是两个孤岛）。
mounts_harvest_state() { # mounts_harvest_state <service>
  awk -v svc="  $1:" '
    $0 == svc { inside = 1; print; next }
    inside && /^  [A-Za-z0-9_-]+:$/ { inside = 0 }
    inside { print }
  ' "${COMPOSE}" | grep -qE ':/var/lib/wist-harvest/state(:|$)'
}
for svc in harvest harvest-bootstrap; do
  if mounts_harvest_state "${svc}"; then
    ok "${svc} 挂了 /var/lib/wist-harvest/state"
  else
    no "${svc} 没挂 /var/lib/wist-harvest/state（身份/租约对不上）"
  fi
done

echo "⑨ 运行态不进交付包（里面有客户端私钥）"
in_section() { # in_section <sys-prj 段名> <行正则>
  awk -v sec="$1" -v pat="$2" '
    $0 ~ "^" sec ":" { inside = 1; next }
    inside && /^[A-Za-z_][A-Za-z0-9_]*:/ { inside = 0 }
    inside && $0 ~ pat { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "${S}/sys-prj.yml"
}
for sec in ignore protect; do
  if in_section "${sec}" '^[[:space:]]*- harvest-run$'; then
    ok "sys-prj.yml 的 ${sec} 收了 harvest-run"
  else
    no "sys-prj.yml 的 ${sec} 没收 harvest-run（升级会覆盖 / 私钥会进包）"
  fi
done
if grep -qE '^/harvest-run/$' "${S}/.gitignore"; then
  ok ".gitignore 挡住了 harvest-run（私钥不入库）"
else
  no ".gitignore 没挡 harvest-run（运行时私钥会被 git 看到）"
fi

printf '\n通过 %d，失败 %d\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
