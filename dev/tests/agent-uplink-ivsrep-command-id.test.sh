#!/usr/bin/env bash
# 门禁：IVSREP 的 `command_id` 能从**帧信封**取到，并且旧帧仍有兜底。
#
# 背景：计算区证据服务要三字段 `{cust_id, cmd_id, content}`，`cmd_id` 是幂等键。
# 报告正文里的 `command_id` 埋在 `body` 字符串里 —— 数据面（WPL/OML）解不了 JSON，
# 用 `json(...)` 解又会丢掉网关调查报告页读的 `body` 原文。所以 agentd 在信封里多带
# 一份，规则用 `opt(chars)@command_id` 读，OML 缺省回落 `event_id`。
#
# 钉五件：
#   1. 信封带 `command_id` → `cmd_id` 就是那个值；
#   2. 旧 agentd 的帧（信封没有该键）→ 规则照常命中，`cmd_id` 回落到事件 id（不为空）；
#   3. 同一 `command_id` 的**重投**（帧其他字段可能不同）→ `cmd_id` 稳定（证据服务的幂等键）；
#   4. 信封值非法（空串 / `null`）→ 回落到事件 id；非字符串（数字）→ 转成字符串做键，
#      **任何一帧都不能因为该字段不合法而丢**；
#   5. 以上所有情况下 `body` 都原样保留（网关按它读报告）。
#
# 模型取**上游 `wp-rules`**（验的是要发布的那份）；sink 用最小 file sink，不依赖
# `wp-infra`（完整投递链路另有 `agent-uplink-ivsrep.test.sh`）。
#
#   dev/tests/agent-uplink-ivsrep-command-id.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
DEV_ROOT="$(cd "${STACK_ROOT}/.." && pwd)"
WPARSE="${WPARSE:-${STACK_ROOT}/dev/bin/wparse}"
DATA_PLANE="${STACK_ROOT}/sys/data-plane"
WP_RULES="${WP_RULES:-${DEV_ROOT}/wp-rules}"

if [[ ! -x "${WPARSE}" ]]; then
  echo "skip: wparse not found or not executable: ${WPARSE}" >&2
  exit 0
fi
[[ -d "${DATA_PLANE}" ]] || { echo "missing data-plane: ${DATA_PLANE}" >&2; exit 1; }
[[ -f "${WP_RULES}/models/wpl/agent_uplink/parse.wpl" ]] || {
  echo "missing wp-rules models: ${WP_RULES}" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM
WORK="${TMP}/work"
cp -R "${DATA_PLANE}" "${WORK}"
# 不继承真实运行目录里的锁 / 旧输出，保证可重复。
rm -rf "${WORK}/.run" "${WORK}/data"

# 用**上游**模型覆盖栈里的副本：验的是要发布的东西。
rm -rf "${WORK}/models/wpl" "${WORK}/models/oml"
cp -R "${WP_RULES}/models/wpl" "${WORK}/models/wpl"
cp -R "${WP_RULES}/models/oml" "${WORK}/models/oml"

# 引擎会对配置文件做全文 ${VAR} 替换（注释也算），knowledge 注释里的占位符会变成
# "vars not value"。测试里把带 ${...} 的注释行剥掉。
if [[ -f "${WORK}/models/knowledge/knowdb.toml" ]]; then
  grep -v '\${' "${WORK}/models/knowledge/knowdb.toml" > "${WORK}/models/knowledge/knowdb.clean.toml"
  mv "${WORK}/models/knowledge/knowdb.clean.toml" "${WORK}/models/knowledge/knowdb.toml"
fi
# 管理面配置在项目根 `wparse.local.toml`（batch 不启管理面）；移除它，测试就不依赖 token 文件。
rm -f "${WORK}/wparse.local.toml"

# 只保留 file source 与一个最小 file sink：不碰网络、不依赖 wp-infra。
rm -rf "${WORK}/topology/sources" "${WORK}/topology/sinks/business.d" "${WORK}/topology/sinks/infra.d"
mkdir -p "${WORK}/topology/sources" "${WORK}/topology/sinks/business.d" \
  "${WORK}/topology/sinks/infra.d" "${WORK}/data/in_dat"

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

cat > "${WORK}/topology/sinks/business.d/agent_ivsrep.toml" <<'EOF'
[sink_group]
name = "agent-ivsrep"
oml = ["agent_uplink_ivsrep"]
batch_size = 1
batch_timeout_ms = 300

[[sink_group.sinks]]
name = "json"
connect = "file_json_sink"

[sink_group.sinks.params]
file = "agent-ivsrep.jsonl"
sync = true
EOF

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

# 八帧：旧 agentd / 新 agentd / 同一 command_id 重投 / 空串 / 数字 / null / 缺失。
# 正文里的 `command_id` 全都保留 —— 它才是网关 join ack 用的那个。
cat > "${WORK}/data/in_dat/gen.dat" <<'EOF'
{"schema":"v1","agent":"agent-old","ts":"2026-10-30T10:00:05Z","seq":1} IVSREP: {"command_id":"cmd_body_only_1","report_schema":"wist.investigation.disk/v1","verdict":"ok"}
{"schema":"v1","agent":"agent-envelope","ts":"2026-10-30T10:00:05Z","seq":2,"command_id":"cmd_envelope_2"} IVSREP: {"command_id":"cmd_envelope_2","report_schema":"wist.investigation.disk/v1","verdict":"ok"}
{"schema":"v1","agent":"agent-replay","ts":"2026-10-30T10:00:05Z","seq":3,"command_id":"cmd_replay_9"} IVSREP: {"command_id":"cmd_replay_9","report_schema":"wist.investigation.disk/v1","verdict":"ok"}
{"schema":"v1","agent":"agent-replay","ts":"2026-10-30T10:00:05Z","seq":3,"command_id":"cmd_replay_9"} IVSREP: {"command_id":"cmd_replay_9","report_schema":"wist.investigation.disk/v1","verdict":"ok"}
{"schema":"v1","agent":"agent-empty-id","ts":"2026-10-30T10:00:05Z","seq":4,"command_id":""} IVSREP: {"command_id":"cmd_body_4","report_schema":"wist.investigation.disk/v1","verdict":"ok"}
{"schema":"v1","agent":"agent-number-id","ts":"2026-10-30T10:00:05Z","seq":5,"command_id":12345} IVSREP: {"command_id":"cmd_body_5","report_schema":"wist.investigation.disk/v1","verdict":"ok"}
{"schema":"v1","agent":"agent-null-id","ts":"2026-10-30T10:00:05Z","seq":6,"command_id":null} IVSREP: {"command_id":"cmd_body_6","report_schema":"wist.investigation.disk/v1","verdict":"ok"}
{"schema":"v1","agent":"agent-absent-id","ts":"2026-10-30T10:00:05Z","seq":7} IVSREP: {"command_id":"cmd_body_7","report_schema":"wist.investigation.disk/v1","verdict":"ok"}
EOF

"${WPARSE}" batch --work-root "${WORK}" >/dev/null

OUT="${WORK}/data/out_dat/agent-ivsrep.jsonl"
[[ -f "${OUT}" ]] || { echo "missing sink output: ${OUT}" >&2; exit 1; }

python3 - "${OUT}" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert len(rows) == 8, f"八帧应产出八条记录（不合法字段不能丢帧），实际 {len(rows)}"

old, env, rep1, rep2, empty, num, null, absent = rows

# 1) 旧帧：信封没有 command_id → 回落到事件 id（非空，且不能凭空造正文里的值）。
assert old["agent"] == "agent-old", old
assert old["cmd_id"] == old["event_id"] and old["cmd_id"], old
assert old["cmd_id"] != "cmd_body_only_1", "旧帧不该从正文里编出 command_id"

# 2) 新帧：信封带 command_id → 直接用它。
assert env["agent"] == "agent-envelope", env
assert env.get("cmd_id") == "cmd_envelope_2", f"新帧 cmd_id 应取信封值，实际 {env.get('cmd_id')}"

# 3) 同一 command_id 重投：cmd_id 必须稳定，否则证据服务会存成两份。
assert rep1["cmd_id"] == rep2["cmd_id"] == "cmd_replay_9", (rep1["cmd_id"], rep2["cmd_id"])

# 4) 非法 / 缺失的信封值：规则不丢帧，`cmd_id` 回落事件 id。
for row, agent in (
    (empty, "agent-empty-id"),
    (null, "agent-null-id"),
    (absent, "agent-absent-id"),
):
    assert row["agent"] == agent, row
    assert row["cmd_id"] == row["event_id"] and row["cmd_id"], row

# 4b) 非字符串（数字）会被转成字符串当键（`12345` 是合法键段，不丢帧、不回落）。
assert num["agent"] == "agent-number-id", num
assert num["cmd_id"] == "12345", f"数字应转成字符串做键，实际 {num.get('cmd_id')!r}"
assert num["cmd_id"] != num["event_id"], num

# 5) 所有帧的正文都必须原样保留（网关调查报告页读 `body`）。
for row in rows:
    body = row.get("body")
    assert isinstance(body, str), f"body 必须是原样字符串，实际 {type(body)}"
    parsed = json.loads(body)
    assert parsed["report_schema"] == "wist.investigation.disk/v1", parsed
    assert parsed["command_id"].startswith("cmd_"), parsed

print("  [OK]   旧帧/空串/null/缺失回落事件 id；信封值直用；重投键稳定；数字转字符串；body 原样")
PY

echo
echo "agent uplink IVSREP command_id test passed"
