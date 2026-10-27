#!/usr/bin/env bash
# 回归测试：`agent_uplink/metrics_frame` 透传逐挂载点标签，且旧帧（不带标签）不受影响。
#
# 钉两件事：
#   1. `metric.mount` / `metric.fstype` 能穿过 WPL + OML，落进 VM JSON line；
#   2. 非文件系统指标没有这两个字段时，OML 不写空标签。
#
# 依赖 `wparse` 二进制（默认 dev/bin/wparse，可用 WPARSE 覆盖）。找不到时跳过，不阻断开发机。
#
#   dev/tests/agent-uplink-metric-labels.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
WPARSE="${WPARSE:-${STACK_ROOT}/dev/bin/wparse}"
DATA_PLANE="${STACK_ROOT}/sys/data-plane"

if [[ ! -x "${WPARSE}" ]]; then
  echo "skip: wparse not found or not executable: ${WPARSE}" >&2
  exit 0
fi
[[ -d "${DATA_PLANE}" ]] || { echo "missing data-plane: ${DATA_PLANE}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM
WORK="${TMP}/work"
cp -R "${DATA_PLANE}" "${WORK}"
# 不继承真实运行目录里的锁/旧输出，保证测试可重复。
rm -rf "${WORK}/.run" "${WORK}/data/out_dat"

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

# 只保留一个业务 sink；infra sink 仍保留（引擎要求 default/miss/error/residue/monitor）。
rm -rf "${WORK}/topology/sinks/business.d"
mkdir -p "${WORK}/topology/sinks/business.d"
cat > "${WORK}/topology/sinks/business.d/test.toml" <<'EOF'
[sink_group]
name = "test-metrics"
oml = ["agent_uplink_metrics_frame"]
batch_size = 1024
batch_timeout_ms = 300

[[sink_group.sinks]]
name = "json"
connect = "file_json_sink"

[sink_group.sinks.params]
file = "test-metrics.json"
EOF
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
{"schema":"agent_uplink","agent":"agent-001","ts":"2026-10-19T08:00:00Z","seq":1} METRICS: {"metric":{"__name__":"system.filesystem.usage","agent":"agent-001","kind":"host_metrics","target_ref":"host-1:host","resource_ref":"host-1","unit":"percent","mount":"/var","fstype":"xfs"},"values":[95.0],"timestamps":[1760860800000]}
{"schema":"agent_uplink","agent":"agent-001","ts":"2026-10-19T08:00:00Z","seq":2} METRICS: {"metric":{"__name__":"system.load_average.1m","agent":"agent-001","kind":"host_metrics","target_ref":"host-1:host","resource_ref":"host-1","unit":"1"},"values":[0.25],"timestamps":[1760860800000]}
EOF

"${WPARSE}" batch --work-root "${WORK}" >/dev/null

OUT="${WORK}/data/out_dat/test-metrics.json"
[[ -f "${OUT}" ]] || { echo "missing output: ${OUT}" >&2; exit 1; }

fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "  [OK]   $1"; else echo "  [FAIL] $1（期望 $2，实际 $3）"; fail=1; fi; }
has() { case "$2" in *"$1"*) echo "  [OK]   $3" ;; *) echo "  [FAIL] $3：$2"; fail=1 ;; esac; }
hasnt() { case "$2" in *"$1"*) echo "  [FAIL] $3：$2"; fail=1 ;; *) echo "  [OK]   $3" ;; esac; }

fs_line="$(grep 'system.filesystem.usage' "${OUT}")"
load_line="$(grep 'system.load_average.1m' "${OUT}")"

has '"mount":"/var"' "${fs_line}" "文件系统指标带 mount 标签"
has '"fstype":"xfs"' "${fs_line}" "文件系统指标带 fstype 标签"
hasnt '"mount"' "${load_line}" "非文件系统指标不写空 mount"
hasnt '"fstype"' "${load_line}" "非文件系统指标不写空 fstype"

if [[ "${fail}" -ne 0 ]]; then
  echo
  echo "输出："
  cat "${OUT}"
  exit 1
fi

echo
echo "agent uplink metric labels test passed"
