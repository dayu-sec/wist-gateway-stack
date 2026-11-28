#!/usr/bin/env bash
# 回归测试：`FLOW:`（主机流记录）能从 agentd 的发帧穿到 `agent-flows` 分组。
#
# 钉三件事：
#   1. `agent_uplink` 的 WPL 认 ` FLOW: ` 标记、OML 产出 `agent_uplink_flow_frame` 记录；
#   2. `business.d/agent_flows.toml` 的路由真的命中（**没有被 `raw_log` 兜走**）；
#   3. 信封字段（agent / seq / ts）与正文 `body` 原样保留（body 是 `wist.host_flow/v1`）。
#
# 模型与 sink 默认取**栈里这份**（`sys/data-plane`）—— 它就是随版本发布的种子。
# 有上游 `wp-rules` / `wp-infra` 时可以用 `WP_RULES` / `WP_INFRA` 指过去，验要发布的那两份。
#
# 依赖 `wparse` 二进制（默认 dev/bin/wparse，可用 WPARSE 覆盖）。找不到时跳过，不阻断开发机。
#
#   dev/tests/agent-uplink-flow.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
# 需要与 `WPARSE_TAG` 同代的 wparse：`agent_flows.toml` 用了 `drop_when_error`
# （0.34 及更早会报 "load sink route confs"）。本地 `dev/bin/wparse` 可能偏旧，
# 用 `WPARSE=/path/to/wparse` 指到新版。
#
# 种子里 `agent-flows` 分组**只有 file sink**：向计算区（field）的投递属于站点
# infra 仓（门禁 `sinks-no-field-delivery.test.sh`），本用例不验那一侧。
# 但记录里的 `cust_id` 必须在 —— 那是站点接上 field 之后分流客户的唯一依据。

WPARSE="${WPARSE:-${STACK_ROOT}/dev/bin/wparse}"
DATA_PLANE="${STACK_ROOT}/sys/data-plane"
WP_RULES="${WP_RULES:-${DATA_PLANE}}"
WP_INFRA="${WP_INFRA:-${DATA_PLANE}}"

if [[ ! -x "${WPARSE}" ]]; then
  echo "skip: wparse not found or not executable: ${WPARSE}" >&2
  exit 0
fi
[[ -f "${WP_RULES}/models/wpl/agent_uplink/parse.wpl" ]] || {
  echo "missing models: ${WP_RULES}" >&2
  exit 1
}
[[ -f "${WP_INFRA}/topology/sinks/business.d/agent_flows.toml" ]] || {
  echo "missing flow sink: ${WP_INFRA}" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM
WORK="${TMP}/work"
cp -R "${DATA_PLANE}" "${WORK}"
# 不继承真实运行目录里的锁/旧输出，保证测试可重复。
rm -rf "${WORK}/.run" "${WORK}/data"

# 用（可能的）上游模型与 sink 覆盖：验的是要发布的东西。
rm -rf "${WORK}/models/wpl" "${WORK}/models/oml"
cp -R "${WP_RULES}/models/wpl" "${WORK}/models/wpl"
cp -R "${WP_RULES}/models/oml" "${WORK}/models/oml"

# 引擎会对配置文件做全文 ${VAR} 替换（注释也算）——测试里把带 ${...} 的注释行剥掉。
if [[ -f "${WORK}/models/knowledge/knowdb.toml" ]]; then
  grep -v '\${' "${WORK}/models/knowledge/knowdb.toml" > "${WORK}/models/knowledge/knowdb.clean.toml"
  mv "${WORK}/models/knowledge/knowdb.clean.toml" "${WORK}/models/knowledge/knowdb.toml"
fi
# 管理面配置在项目根 `wparse.local.toml`（batch 不启管理面），移除后不依赖 token 文件。
rm -f "${WORK}/wparse.local.toml"

# 只保留 file source，避免测试去 bind TCP/syslog 端口。
rm -rf "${WORK}/topology/sources"
mkdir -p "${WORK}/topology/sources"
cat > "${WORK}/topology/sources/file_1.toml" <<'EOF'
key = "file_1"
enable = true
connect = "file_src"
tags = []

[params]
base = "./data/in_dat"
data_format = "ndjson"
encode = "text"
file = "gen.dat"
EOF

# 只保留流记录 sink：如果帧没被这条路由接住，就**一个文件都不会有**（不是“落错地方”）。
rm -rf "${WORK}/topology/sinks/business.d"
mkdir -p "${WORK}/topology/sinks/business.d"
cp "${WP_INFRA}/topology/sinks/business.d/agent_flows.toml" \
  "${WORK}/topology/sinks/business.d/agent_flows.toml"

# monitor 原配置引用 ${WPARSE_VM_ENDPOINT}（本测试不跑它）：换成纯文件 sink，输出干净。
cat > "${WORK}/topology/sinks/infra.d/monitor.toml" <<'EOF'
[sink_group]
name = "monitor"
batch_size = 1
batch_timeout_ms = 300

[[sink_group.sinks]]
connect = "file_proto_text_sink"

[sink_group.sinks.params]
file = "monitor.dat"

[sink_group.sinks.expect]
max = 1.0
EOF

# 租户绑定：`gwlinkd` 平时把身份写进工作根 `.env` 的 `WP_GLOBAL_TAGS`（全局 tag），
# OML 的 `read(tenant_id)` 读的就是它（与 DSNAP / IVSREP 同一条机制；
# 见 `agent-uplink-metric-labels.test.sh` 的同一段）。`WIST_TENANT_ID` 一并写，
# 那是引擎注入记录级 `tenant_id` 用的。
printf 'WP_GLOBAL_TAGS=tenant_id=1000000000000000001,wist-gw_id=X4/inst-1\nWIST_TENANT_ID=1000000000000000001\n' > "${WORK}/.env"

mkdir -p "${WORK}/data/in_dat"
cat > "${WORK}/data/in_dat/gen.dat" <<'EOF'
{"schema":"v1","agent":"agent-host-d97e23da6111","ts":"2026-11-26T04:16:42Z","seq":100231} FLOW: {"record_schema":"wist.host_flow/v1","source":"host_ebpf","coverage":"host_partial","capture":"tc_egress","collector_instance_id":"agent-host-d97e23da6111","host_id":"host-d97e23da6111","host_name":"vm-web-01","kernel":"5.15.0-91-generic","ifname":"eth0","ifindex":2,"if_mac":"52:54:00:aa:bb:cc","local_addrs":["10.118.0.14"],"direction":"out","protocol":"6","srcaddr":"10.118.0.14","dstaddr":"88.214.25.121","srcport":"50123","dstport":"443","start":1789469760,"end":1789469820,"window_seconds":60,"packets":13,"bytes":1460,"wire_bytes_source":"unavailable","skb_count":4,"gso_skb_count":1,"truncated":false,"dropped":0}
EOF

"${WPARSE}" batch --work-root "${WORK}" >/dev/null

OUT="${WORK}/data/out_dat/agent-flows.jsonl"
[[ -f "${OUT}" ]] || {
  echo "missing flow sink output: ${OUT}（帧很可能被兜进 raw_log 或直接丢了）" >&2
  exit 1
}

fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "  [OK]   $1"; else echo "  [FAIL] $1（期望 $2，实际 $3）"; fail=1; fi; }
has() { case "$2" in *"$1"*) echo "  [OK]   $3" ;; *) echo "  [FAIL] $3：$2"; fail=1 ;; esac; }

line="$(head -n 1 "${OUT}")"

chk "一帧进 → 一条记录出" "1" "$(wc -l < "${OUT}" | tr -d ' ')"

# 信封：归属与去重全靠它。
has '"agent":"agent-host-d97e23da6111"' "${line}" "信封 agent 原样保留"
has '"seq":100231' "${line}" "信封 seq 保留（数据面去重的键）"
has '"ts":"2026-11-26T04:16:42Z"' "${line}" "信封 ts 保留"
has '"log_type":"agent_uplink_flow_frame"' "${line}" "log_type 命中流记录分组"

# 正文是契约对象原样（JSON **字符串**，引号被转义）。数据面不拆字段，靠它把这层留给下游。
has 'record_schema\":\"wist.host_flow/v1' "${line}" "正文里的 record_schema 保留"
has 'collector_instance_id\":\"agent-host-d97e23da6111' "${line}" "正文里的 collector_instance_id 保留（幂等键）"
has 'direction\":\"out' "${line}" "正文里的 direction 保留"

# 客户归属：OML 用 `cust_id = read(tenant_id)`，租户由网关绑定时写进工作根 `.env`
# （与 DSNAP / IVSREP 同一条机制）。未绑定时是占位 `unknown`，证据服务会按
# "未登记客户"拒 —— 所以这个字段必须在。
has '"cust_id":"1000000000000000001"' "${line}" "记录带 cust_id（客户归属，来自租户绑定）"

if [[ "${fail}" -ne 0 ]]; then
  echo
  echo "输出："
  cat "${OUT}"
  exit 1
fi

echo
echo "agent uplink FLOW test passed"
