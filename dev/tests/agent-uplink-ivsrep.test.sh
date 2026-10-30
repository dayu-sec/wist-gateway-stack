#!/usr/bin/env bash
# 回归测试：`IVSREP:`（一次性调查报告）能从 agentd 的发帧穿到网关读取的那个目录。
#
# 钉三件事：
#   1. `wp-rules` 的 WPL 认 ` IVSREP: ` 标记、OML 产出 `agent_uplink_ivsrep_frame` 记录；
#   2. `wp-infra` 的 `agent_ivsrep` sink 确实落在 `./data/ivsrep/`（网关 `REPORT_DIR` 就按它推导）；
#   3. 信封字段（agent / seq / ts）与正文 `body` 原样保留（body 是带 `command_id` 的契约对象）。
#
# 模型与 sink 都从**上游仓**（`wp-rules` / `wp-infra`）覆盖进来再跑 —— 验的是要发布的那两份，
# 不是栈里那份手抄副本。
#
# 依赖 `wparse` 二进制（默认 dev/bin/wparse，可用 WPARSE 覆盖）。找不到时跳过，不阻断开发机。
#
#   dev/tests/agent-uplink-ivsrep.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
DEV_ROOT="$(cd "${STACK_ROOT}/.." && pwd)"
WPARSE="${WPARSE:-${STACK_ROOT}/dev/bin/wparse}"
DATA_PLANE="${STACK_ROOT}/sys/data-plane"
WP_RULES="${WP_RULES:-${DEV_ROOT}/wp-rules}"
WP_INFRA="${WP_INFRA:-${DEV_ROOT}/wp-infra}"

if [[ ! -x "${WPARSE}" ]]; then
  echo "skip: wparse not found or not executable: ${WPARSE}" >&2
  exit 0
fi
[[ -d "${DATA_PLANE}" ]] || { echo "missing data-plane: ${DATA_PLANE}" >&2; exit 1; }
[[ -f "${WP_RULES}/models/wpl/agent_uplink/parse.wpl" ]] || {
  echo "missing wp-rules models: ${WP_RULES}" >&2
  exit 1
}
[[ -f "${WP_INFRA}/topology/sinks/business.d/agent_ivsrep.toml" ]] || {
  echo "missing wp-infra sink: ${WP_INFRA}" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM
WORK="${TMP}/work"
cp -R "${DATA_PLANE}" "${WORK}"
# 不继承真实运行目录里的锁/旧输出，保证测试可重复。
rm -rf "${WORK}/.run" "${WORK}/data"

# 用**上游**的模型与 sink 覆盖栈里的副本：验的是要发布的东西。
rm -rf "${WORK}/models/wpl" "${WORK}/models/oml"
cp -R "${WP_RULES}/models/wpl" "${WORK}/models/wpl"
cp -R "${WP_RULES}/models/oml" "${WORK}/models/oml"

# 引擎会对配置文件做全文 ${VAR} 替换（注释也算），knowledge 注释里的占位符会变成
# “vars not value”。测试里把带 ${...} 的注释行剥掉。
if [[ -f "${WORK}/models/knowledge/knowdb.toml" ]]; then
  grep -v '\${' "${WORK}/models/knowledge/knowdb.toml" > "${WORK}/models/knowledge/knowdb.clean.toml"
  mv "${WORK}/models/knowledge/knowdb.clean.toml" "${WORK}/models/knowledge/knowdb.toml"
fi
# 管理面配置在项目根 `wparse.local.toml`（batch 不启管理面）；移除它，测试就不依赖 token 文件。
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

# 只保留**上游那份**调查报告 sink（落 ./data/ivsrep/，正是网关读的目录）。
rm -rf "${WORK}/topology/sinks/business.d"
mkdir -p "${WORK}/topology/sinks/business.d"
cp "${WP_INFRA}/topology/sinks/business.d/agent_ivsrep.toml" \
  "${WORK}/topology/sinks/business.d/agent_ivsrep.toml"

# monitor 原配置含 ${WPARSE_VM_ENDPOINT}；测试里只保留文件 sink。
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

mkdir -p "${WORK}/data/in_dat"
cat > "${WORK}/data/in_dat/gen.dat" <<'EOF'
{"schema":"v1","agent":"agent-001","ts":"2026-10-30T10:00:05Z","seq":7} IVSREP: {"command":"investigate","topic":"disk","report_schema":"wist.investigation.disk/v1","command_id":"cmd_agent-001_investigate_1","observed_at":"2026-10-30T10:00:05Z","findings":[{"id":"disk.filesystems","status":"warn","title":"磁盘偏紧","detail":"/ 88.0% 已用","hint":null,"rows":[{"label":"/","value":"88.0% 已用","note":"1.0 TiB / 1.2 TiB"}]}],"summary":{"ok":2,"warn":1,"fail":0,"overall":"warn"},"verdict":"2 项正常 / 1 项警告 / 0 项失败"}
EOF

"${WPARSE}" batch --work-root "${WORK}" >/dev/null

# 网关按 `<work_dir>/data/ivsrep` 读（`api/investigations.rs` 的 REPORT_DIR）——
# 路径错了这个测试必须红，否则现场表现是“agentd 说发了、页面永远空”。
OUT="${WORK}/data/ivsrep/agent-ivsrep.jsonl"
[[ -f "${OUT}" ]] || { echo "missing report sink output: ${OUT}" >&2; exit 1; }

fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "  [OK]   $1"; else echo "  [FAIL] $1（期望 $2，实际 $3）"; fail=1; fi; }
has() { case "$2" in *"$1"*) echo "  [OK]   $3" ;; *) echo "  [FAIL] $3：$2"; fail=1 ;; esac; }

line="$(head -n 1 "${OUT}")"

# 一帧进 → 一条记录出：多一行意味着 OML 把同一帧拆成了两条（网关会当成两次投递）。
chk "一条输入帧只产出一条报告记录" "1" "$(wc -l < "${OUT}" | tr -d ' ')"

# 信封：归属只看它（与网关内部接入端点同一条纪律）。
has '"agent":"agent-001"' "${line}" "信封里的 agent 原样保留（报告归属全靠它）"
has '"seq":7' "${line}" "信封 seq 保留（数据面去重的键）"
has '"ts":"2026-10-30T10:00:05Z"' "${line}" "信封 ts 保留"
# OML 产出的 log_type：应落进 `agent_uplink_ivsrep_frame` 这一组记录。
has '"log_type":"agent_uplink_ivsrep_frame"' "${line}" "log_type 命中调查报告"
# 正文是契约对象原样（以 JSON **字符串** 落 `body`，引号被转义 —— 这就是网关读到的形状）。
# 网关靠 command_id join ack、靠 report_schema 选渲染。
has 'command_id\":\"cmd_agent-001_investigate_1' "${line}" "正文里的 command_id 保留（与 ack 关联）"
has 'report_schema\":\"wist.investigation.disk/v1' "${line}" "正文里的 report_schema 保留"

if [[ "${fail}" -ne 0 ]]; then
  echo
  echo "输出："
  cat "${OUT}"
  exit 1
fi

echo
echo "agent uplink IVSREP test passed"
