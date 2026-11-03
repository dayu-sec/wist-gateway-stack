#!/usr/bin/env bash
# 回归测试：`agent_uplink/metrics_frame` 透传**全部序列 label 与选择类 label**，且旧帧（不带标签）不受影响。
#
# 钉五件事：
#   1. 序列 label（`instance` / `mountpoint` / `fstype` / `disk_role` …）能穿过 WPL + OML，落进 VM JSON line；
#   2. 指标没有这些字段时，OML 不写空标签；
#   3. `metric.tenant_id` 只认**网关全局 tag**（gwlinkd 写进工作根 `.env` 的
#      `WP_GLOBAL_TAGS=tenant_id=...`）：未绑定时**不写**这个键（不能是空串、也不能是模型常量）；
#      绑定后它就是 VM 上的租户标签 —— VM 靠它按租户隔离序列。
#   4. 选择类 label（`env` / `cluster` / `app` / `role` … 网关下发）同样要进 `metric`，
#      没配就不写 —— 否则 `env=""` 会把序列按空值分组。注意与引擎在顶层注入的 `env`
#      （部署环境）不是一回事，所以断言只看 `metric` 对象。
#   5. 挂载点 label 的名字是 `mountpoint`（规范 §3 的样例帧），旧名 `mount` 不得再产出。
#   6. **满字段帧**：把 agentd 能发的 `metric.*` 字段全部填满，输出 `metric` 的键集合必须与
#      输入帧逐键相等 —— 少一个（WPL/OML 没搬）或多一个（OML 凭空造）都算失败。
#      这条是唯一能挡住「静默丢维度」的结构性防线。
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
{"schema":"agent_uplink","agent":"agent-001","ts":"2026-10-19T08:00:00Z","seq":1} METRICS: {"metric":{"__name__":"system.filesystem.usage","agent":"agent-001","instance":"host-1:host","kind":"host_metrics","target_ref":"host-1:host","resource_ref":"host-1","unit":"percent","disk_role":"system","mountpoint":"/var","fstype":"xfs","env":"prod","cluster":"kafka-prod","app":"kafka","role":"broker"},"values":[95.0],"timestamps":[1760860800000]}
{"schema":"agent_uplink","agent":"agent-001","ts":"2026-10-19T08:00:00Z","seq":2} METRICS: {"metric":{"__name__":"system.load_average.1m","agent":"agent-001","instance":"host-1:host","kind":"host_metrics","target_ref":"host-1:host","resource_ref":"host-1","unit":"1"},"values":[0.25],"timestamps":[1760860800000]}
{"schema":"agent_uplink","agent":"agent-001","ts":"2026-10-19T08:00:00Z","seq":3} METRICS: {"metric":{"__name__":"agent_memory_bytes","agent":"agent-001","instance":"host-1:host","kind":"host_metrics","target_ref":"host-1:host","resource_ref":"host-1","unit":"bytes","disk_role":"data","mountpoint":"/data","fstype":"ext4","device":"/dev/sdb1","cpu":"cpu0","mode":"rw","state":"up","target_kind":"disk","outcome":"succeeded","env":"prod","cluster":"kafka-prod","app":"kafka","role":"broker","shard":"3","tier":"hot","region":"cn-north","zone":"az-1"},"values":[1048576],"timestamps":[1760860800000]}
EOF

"${WPARSE}" batch --work-root "${WORK}" >/dev/null

OUT="${WORK}/data/out_dat/test-metrics.json"
[[ -f "${OUT}" ]] || { echo "missing output: ${OUT}" >&2; exit 1; }

fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "  [OK]   $1"; else echo "  [FAIL] $1（期望 $2，实际 $3）"; fail=1; fi; }
has() { case "$2" in *"$1"*) echo "  [OK]   $3" ;; *) echo "  [FAIL] $3：$2"; fail=1 ;; esac; }
hasnt() { case "$2" in *"$1"*) echo "  [FAIL] $3：$2"; fail=1 ;; *) echo "  [OK]   $3" ;; esac; }

out_json() { python3 -c '
import json, sys
for line in open(sys.argv[1]):
    rec = json.loads(line)
    print(rec["metric"]["__name__"], json.dumps(rec.get("metric"), ensure_ascii=False))
' "$1"; }

fs_line="$(grep 'system.filesystem.usage' "${OUT}")"
load_line="$(grep 'system.load_average.1m' "${OUT}")"
fs_metric="$(out_json "${OUT}" | grep '^system.filesystem.usage')"
load_metric="$(out_json "${OUT}" | grep '^system.load_average.1m')"

has '"mountpoint":"/var"' "${fs_line}" "文件系统指标带 mountpoint 标签"
has '"fstype":"xfs"' "${fs_line}" "文件系统指标带 fstype 标签"
hasnt '"mountpoint"' "${load_line}" "非文件系统指标不写空 mountpoint"
hasnt '"fstype"' "${load_line}" "非文件系统指标不写空 fstype"
# 旧名 `mount` 是历史误写（agentd 发的是 `mountpoint`）：改名后不得再出现，否则同一份数据会有两种 key。
hasnt '"mount"' "${fs_metric}" "不再产出旧名 mount"

# 2.5) 序列 label 与选择类 label（网关下发）：全部要进 `metric`（VM 只认 metric 对象里的 label）。
#      只看 metric 对象：顶层那个 `env` 是引擎注入的部署环境（恒为 dev），不是选择层。
has '"instance": "host-1:host"' "${fs_metric}" "序列 label instance 进 metric"
has '"disk_role": "system"' "${fs_metric}" "序列 label disk_role 进 metric"
has '"env": "prod"' "${fs_metric}" "选择类 label env 进 metric"
has '"cluster": "kafka-prod"' "${fs_metric}" "选择类 label cluster 进 metric"
has '"app": "kafka"' "${fs_metric}" "选择类 label app 进 metric"
has '"role": "broker"' "${fs_metric}" "选择类 label role 进 metric"
hasnt '"env"' "${load_metric}" "未配选择层时不写空 env"
hasnt '"cluster"' "${load_metric}" "未配选择层时不写空 cluster"
hasnt '"app"' "${load_metric}" "未配选择层时不写空 app"

# 2.6) 满字段帧：输入的 `metric` 键必须与契约表一致，且**逐键**出现在输出 `metric` 里。
#      少一个 = WPL/OML 少搬了一个维度（`mount`→`mountpoint` 就这么静默丢过）；
#      多一个 = OML 凭空造了 agentd 没发的键。两种都不允许。
#      另查扁平 `metric_<k>` 与嵌套 `metric.<k>` 同集同值（中心侧读扁平、VM 读嵌套）。
#      `tenant_id` 不在此列 —— 它由网关全局 tag 注入，见 4)。
if ! python3 - "${WORK}/data/in_dat/gen.dat" "${OUT}" <<'PY'
import json
import sys

# 契约表：agentd 上送的 `metric.*` 可透传字段（数组类 values/timestamps 与 tenant_id 不在此列）。
CANON = [
    "__name__", "agent", "instance", "kind", "target_ref", "resource_ref", "unit",
    "disk_role", "mountpoint", "fstype", "device", "cpu", "mode", "state",
    "target_kind", "outcome",
    "env", "cluster", "app", "role", "shard", "tier", "region", "zone",
]

src = None
for line in open(sys.argv[1], encoding="utf-8"):
    if "agent_memory_bytes" not in line:
        continue
    frame = json.loads(line.split("METRICS: ", 1)[1])
    src = sorted(frame["metric"].keys())
    break

out = None
out_rec = None
for line in open(sys.argv[2], encoding="utf-8"):
    rec = json.loads(line)
    if rec["metric"].get("__name__") == "agent_memory_bytes":
        out_rec = rec
        out = sorted(rec["metric"].keys())
        break

ok = True
if src is None:
    print("  [FAIL] 满字段帧没出现在输入里")
    ok = False
elif out is None:
    print("  [FAIL] 满字段帧没有产出输出")
    ok = False
else:
    if src != sorted(CANON):
        print("  [FAIL] 测试帧字段与契约表不一致: " + json.dumps(src, ensure_ascii=False))
        ok = False
    missing = [k for k in src if k not in out]
    extra = [k for k in out if k not in src]
    if missing:
        print("  [FAIL] 输出 metric 丢了字段（WPL/OML 少搬）: " + ", ".join(missing))
        ok = False
    if extra:
        print("  [FAIL] 输出 metric 多出字段（OML 凭空造）: " + ", ".join(extra))
        ok = False

    # 2.6.1) 双表示不许漂移。OML 同一份数据产出两套：
    #  * 嵌套 `metric.<k>`  —— VM 只认这个；
    #  * 扁平 `metric_<k>`  —— 文件/中心侧的现有消费方在用。
    # 只改一边（典型：嵌套改了名、扁平没改）时两边单测都绿，但其中一半消费者静默失联。
    flat_missing, flat_mismatch = [], []
    for k in src:
        flat_key = "metric_name" if k == "__name__" else "metric_" + k
        if flat_key not in out_rec:
            flat_missing.append(flat_key)
        elif out_rec[flat_key] != out_rec["metric"][k]:
            flat_mismatch.append("{}={!r} vs metric.{}".format(flat_key, out_rec[flat_key], k))
    if flat_missing:
        print("  [FAIL] 满字段帧缺少扁平字段（只写了嵌套）: " + ", ".join(flat_missing))
        ok = False
    if flat_mismatch:
        print("  [FAIL] 扁平字段与嵌套 metric 不一致: " + "; ".join(flat_mismatch))
        ok = False

    if ok:
        print("  [OK]   满字段帧 %d 个 metric 键全部透传且扁平/嵌套一致" % len(src))

sys.exit(0 if ok else 1)
PY
then
  fail=1
fi

# 3) 未绑定租户（没有 WP_GLOBAL_TAGS）：metric 里**一条** tenant_id 都不该有 ——
#    写空串会让 VM 多出一条 tenant_id="" 的序列，比没有更糟。
hasnt '"tenant_id"' "$(out_json "${OUT}")" "未绑定租户时 metric 不写 tenant_id"

# 4) 绑定后：gwlinkd 把身份写进工作根 `.env` 的 WP_GLOBAL_TAGS，OML 读全局 tag →
#    `metric.tenant_id` 必须就是那个值（VM 的租户标签就是从这里来的）。
printf 'WP_GLOBAL_TAGS=tenant_id=1000000000000000001,wist-gw_id=X4/inst-1\nWIST_TENANT_ID=1000000000000000001\n' \
  > "${WORK}/.env"
rm -rf "${WORK}/data/out_dat" "${WORK}/.run"
"${WPARSE}" batch --work-root "${WORK}" >/dev/null
has '"tenant_id": "1000000000000000001"' "$(out_json "${OUT}")" "绑定后 metric.tenant_id 来自 WP_GLOBAL_TAGS"

if [[ "${fail}" -ne 0 ]]; then
  echo
  echo "输出："
  cat "${OUT}"
  exit 1
fi

echo
echo "agent uplink metric labels test passed"
