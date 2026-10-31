#!/usr/bin/env bash
# 门禁：`scripts/import-package.sh --set` 发出的请求体必须被**当前网关**接受。
#
# 为什么单列一条：2026-10-31 现场，包已经放进 `packages/` 了，但「设为分发来源」一直
# HTTP 422 —— 脚本还在发旧版平铺请求体 `{package_url, package_sha256}`，而网关 v0.28+
# 要求 `{artifacts:[{platform, package_url, package_sha256}]}`（`missing field artifacts`）。
# 这类漂移在 Ui 上只表现为「设不上」，最容易在真实发布时才被发现，所以在这里钉住：
#   * 请求体形状（artifacts 数组、每项三个字段）；
#   * 平台名从文件名正确推导（`0.13.1-alpha` 里的连字符不能把 triple 切坏）；
#   * `--latest` 在目录里**每平台各取一份**（只取最新一个会让别的架构拿到错包）。
#
# 跑法：`dev/tests/import-package-payload.test.sh`（缺 python3 则跳过，不阻断开发机）。
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
SCRIPT="${STACK_ROOT}/scripts/import-package.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "skip: python3 not found（只用它起一个收请求体的桩服务）" >&2
  exit 0
fi
[[ -f "${SCRIPT}" ]] || { echo "missing script: ${SCRIPT}" >&2; exit 1; }

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [[ -z "${SERVER_PID}" ]] || kill "${SERVER_PID}" 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

# 两个平台各一个假包（内容无关：本门禁只看请求体，真正的包校验在网关侧）。
mkdir -p "${TMP}/src" "${TMP}/packages"
: > "${TMP}/src/wist-agentd-v0.13.1-alpha-aarch64-apple-darwin.tar.gz"
: > "${TMP}/src/wist-agentd-v0.13.1-alpha-x86_64-unknown-linux-musl.tar.gz"

BODY="${TMP}/body.json"
PORT_FILE="${TMP}/port"
cat > "${TMP}/stub.py" <<'PY'
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        with open(sys.argv[1], "wb") as f:
            f.write(self.rfile.read(n))
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"packages":[]}')

    def log_message(self, *args):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[2], "w") as f:
    f.write(str(srv.server_port))
srv.serve_forever()
PY
python3 "${TMP}/stub.py" "${BODY}" "${PORT_FILE}" &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [[ -s "${PORT_FILE}" ]] && break
  sleep 0.05
done
PORT="$(cat "${PORT_FILE}")"
[[ -n "${PORT}" ]] || { echo "桩服务没起来" >&2; exit 1; }

GATEWAY_URL="http://127.0.0.1:${PORT}" \
ADMIN_TOKEN="test-token" \
PACKAGE_DIR="${TMP}/packages" \
AGENTD_PKG_DIR="${TMP}/src" \
  "${SCRIPT}" --latest --set >"${TMP}/out" 2>&1 || {
  echo "import-package.sh 失败：" >&2
  cat "${TMP}/out" >&2
  exit 1
}

python3 - "${BODY}" <<'PY'
import json
import sys

body = open(sys.argv[1], "rb").read()
assert body, "脚本没有发出请求体（--set 没生效？）"
payload = json.loads(body)
assert "artifacts" in payload, f"请求体少了 artifacts（旧版形状）：{payload}"
artifacts = payload["artifacts"]
assert isinstance(artifacts, list) and len(artifacts) == 2, artifacts
platforms = sorted(a["platform"] for a in artifacts)
assert platforms == ["aarch64-apple-darwin", "x86_64-unknown-linux-musl"], platforms
for artifact in artifacts:
    assert artifact["package_url"].startswith(
        "/packages/wist-agentd-"
    ), artifact
    digest = artifact["package_sha256"]
    assert digest.startswith("sha256:") and len(digest) == 71, digest
PY
echo "ok: --latest 按平台各取一份，请求体形状正确"

# 文件名不带已知平台 → 必须**明确失败**，而不是拿一个猜出来的平台去设来源。
if "${SCRIPT}" "${TMP}/src/whatever.tar.gz" >"${TMP}/bad-out" 2>&1; then
  # 文件不存在也要失败；两种失败都可接受，成功不行。
  echo "期望失败但成功了：" >&2
  cat "${TMP}/bad-out" >&2
  exit 1
fi
: > "${TMP}/src/wist-agentd-v9.9.9-alpha-nonsense.tar.gz"
if "${SCRIPT}" "${TMP}/src/wist-agentd-v9.9.9-alpha-nonsense.tar.gz" >"${TMP}/bad-out" 2>&1; then
  echo "平台识别不了时不能静默成功：" >&2
  cat "${TMP}/bad-out" >&2
  exit 1
fi
grep -q "无法从文件名判断平台" "${TMP}/bad-out" || {
  echo "失败信息要说清是平台识别问题：" >&2
  cat "${TMP}/bad-out" >&2
  exit 1
}
echo "ok: 平台识别不了时明确失败"
