#!/usr/bin/env bash
# 门禁：计算区数据场（field）的三个写入端点必须能用 `connect = "wist-field-*"` 复用。
#
# 背景：这三段配置原先散在 `business.d/*.toml` 里（endpoint / fmt / batch_size / 超时
# 各写一遍），换地址要逐份改、格式写错还不会报错（atlas 收到数组会回 400 再落 rescue）。
# 现在收敛到 `connectors/sink.d/24-wist-field_sinks.toml`：
#   * `wist-field-evidence` —— POST <FIELD_EVIDENCE_URL>/internal/evidence，fmt=json；
#   * `wist-field-atlas`    —— POST <FIELD_ATLAS_URL>/internal/atlas，**fmt=ndjson**（单对象）；
#   * `wist-field-metrics`  —— POST <FIELD_METRICS_URL>/api/v1/import，fmt=ndjson。
#
# 钉四件（都是「静默错」才会踩的）：
#   1. 三个连接器都能被 sink 用 `connect` 解析（id 带连字符也要认）；
#   2. 连接器参数里的 `${VAR:默认}` 能展开 —— 站点靠环境变量换地址，不改配置；
#   3. sink **不写** `[sink_group.sinks.params]` 也能跑（参数全部来自连接器）；
#   4. 报文形状对：证据是 JSON 数组（服务两种都收），atlas / VM 是 **ndjson 单行对象**
#      （atlas 收到数组会 400）。
#
# 依赖 `wparse`（默认 dev/bin/wparse，可用 WPARSE 覆盖）与 python3；缺了跳过。
#
#   dev/tests/wist-field-connectors.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
WPARSE="${WPARSE:-${STACK_ROOT}/dev/bin/wparse}"
DATA_PLANE="${STACK_ROOT}/sys/data-plane"

if [[ ! -x "${WPARSE}" ]]; then
  echo "skip: wparse not found or not executable: ${WPARSE}" >&2
  exit 0
fi
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found" >&2; exit 0; }
[[ -d "${DATA_PLANE}" ]] || { echo "missing data-plane: ${DATA_PLANE}" >&2; exit 1; }

TMP="$(mktemp -d)"
STUB_PID=""
cleanup() {
  [[ -n "${STUB_PID}" ]] && kill "${STUB_PID}" 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

WORK="${TMP}/work"
cp -R "${DATA_PLANE}" "${WORK}"
rm -rf "${WORK}/.run" "${WORK}/data"
rm -f "${WORK}/wparse.local.toml"

# 记录收到的请求：路径 / Content-Type / 正文。端口由内核分配，写进 $TMP/port。
cat > "${TMP}/stub.py" <<'PY'
import http.server, json, os, sys

outdir = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        with open(os.path.join(outdir, "requests.jsonl"), "a", encoding="utf-8") as handle:
            handle.write(json.dumps({
                "path": self.path,
                "ctype": self.headers.get("content-type"),
                "body": body,
            }) + "\n")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *_args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(outdir, "port"), "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY

python3 "${TMP}/stub.py" "${TMP}" &
STUB_PID=$!
for _ in $(seq 1 50); do
  [[ -s "${TMP}/port" ]] && break
  sleep 0.1
done
[[ -s "${TMP}/port" ]] || { echo "[FAIL] stub 没起来" >&2; exit 1; }
PORT="$(cat "${TMP}/port" || true)"

# 站点侧通常会在这份 OML 末尾补上 field 要的三字段（`cust_id` / `cmd_id` / `content`）。
# 种子模型**不含**它们（客户 id 是站点值，不该进产品默认），所以测试里按站点的方式补一次：
# 这样验的就是「连接器 + 站点 OML」拼起来后，证据服务真能收到幂等键。
IVSREP_OML="${WORK}/models/oml/agent_uplink/agent_uplink_ivsrep/adm.oml"
[[ -f "${IVSREP_OML}" ]] || { echo "missing OML: ${IVSREP_OML}" >&2; exit 1; }
cat >> "${IVSREP_OML}" <<'EOF'
// 测试用站点覆盖：field 证据要的三字段。
cust_id = chars(c-001);
cmd_id = read(option:[command_id, event_id]);
content = read(body);
EOF

# 只留 file source：本门禁不关心解析结果，只要一帧流过去。
rm -rf "${WORK}/topology/sources"
mkdir -p "${WORK}/topology/sources" "${WORK}/data/in_dat"
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

# 一个分组、三个 sink，全部只写 `connect = "wist-field-*"`（不写 params）。
# 同一条记录扇出到三个端点：正好验「连接器参数全部来自连接器本身」。
rm -rf "${WORK}/topology/sinks/business.d"
mkdir -p "${WORK}/topology/sinks/business.d"
cat > "${WORK}/topology/sinks/business.d/field.toml" <<'EOF'
[sink_group]
name = "field-fanout"
oml = ["agent_uplink_ivsrep"]
batch_size = 1
batch_timeout_ms = 300

[[sink_group.sinks]]
name = "evidence"
connect = "wist-field-evidence"

[[sink_group.sinks]]
name = "atlas"
connect = "wist-field-atlas"

[[sink_group.sinks]]
name = "metrics"
connect = "wist-field-metrics"
EOF

cat > "${WORK}/data/in_dat/gen.dat" <<'EOF'
{"schema":"v1","agent":"agent-001","ts":"2026-10-30T10:00:05Z","seq":7,"command_id":"cmd_field_1"} IVSREP: {"command":"investigate","topic":"disk","report_schema":"wist.investigation.disk/v1","command_id":"cmd_field_1","verdict":"ok"}
EOF

WPARSE_VM_ENDPOINT="http://127.0.0.1:1" \
FIELD_EVIDENCE_URL="http://127.0.0.1:${PORT}" \
FIELD_ATLAS_URL="http://127.0.0.1:${PORT}" \
FIELD_METRICS_URL="http://127.0.0.1:${PORT}" \
  "${WPARSE}" batch --work-root "${WORK}" >"${TMP}/wparse.log" 2>&1

REQUESTS="${TMP}/requests.jsonl"
[[ -f "${REQUESTS}" ]] || {
  echo "[FAIL] 三个端点一个请求都没收到（连接器没生效？）" >&2
  tail -30 "${TMP}/wparse.log" >&2
  exit 1
}

python3 - "${REQUESTS}" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]

failures = []


def check(ok, message):
    print(("  [OK]   " if ok else "  [FAIL] ") + message)
    if not ok:
        failures.append(message)


paths = sorted(row["path"] for row in rows)
check(
    paths == ["/api/v1/import", "/internal/atlas", "/internal/evidence"],
    f"三个端点各收到一次请求（实际 {paths}）",
)

by_path = {row["path"]: row for row in rows}
evidence = by_path.get("/internal/evidence")
atlas = by_path.get("/internal/atlas")
metrics = by_path.get("/api/v1/import")

if evidence:
    check(
        (evidence["ctype"] or "").startswith("application/json"),
        "证据端点带 Content-Type: application/json",
    )
    try:
        parsed = json.loads(evidence["body"])
    except json.JSONDecodeError:
        parsed = None
    check(isinstance(parsed, list), "证据端点收到 JSON **数组**（fmt=json，服务两种都收）")
    check(
        isinstance(parsed, list) and parsed and parsed[0].get("cmd_id") == "cmd_field_1",
        "证据报文里的 cmd_id 来自帧信封（幂等键）",
    )
else:
    check(False, "证据端点收到请求")

if atlas:
    body = atlas["body"].strip()
    lines = [line for line in body.splitlines() if line.strip()]
    check(len(lines) == 1, f"atlas 端点收到单行（实际 {len(lines)} 行）")
    try:
        parsed = json.loads(lines[0]) if lines else None
    except json.JSONDecodeError:
        parsed = None
    check(
        isinstance(parsed, dict),
        "atlas 报文是**单个对象**，不是数组（fmt=ndjson）——投 json 会被回 400",
    )
else:
    check(False, "atlas 端点收到请求")

if metrics:
    body = metrics["body"].strip()
    lines = [line for line in body.splitlines() if line.strip()]
    check(len(lines) == 1, f"VM 端点收到单行 ndjson（实际 {len(lines)} 行）")
    try:
        parsed = json.loads(lines[0]) if lines else None
    except json.JSONDecodeError:
        parsed = None
    check(isinstance(parsed, dict), "VM 报文是 ndjson 单行对象")
else:
    check(False, "VM 端点收到请求")

if failures:
    print()
    print("请求明细：")
    print(json.dumps(rows, ensure_ascii=False, indent=2)[:4000])
    sys.exit(1)
PY

# sink 里不该再出现端点变量：写了就说明没收敛到连接器，换地址会漏改。
if grep -Eqs 'endpoint =|_URL|SINK_URL|CONSOLE_VM_ENDPOINT' "${WORK}/topology/sinks/business.d/field.toml"; then
  echo "[FAIL] sink 里还在拼端点变量：应全部走 wist-field-* 连接器" >&2
  exit 1
fi

echo
echo "wist-field connectors test passed"
