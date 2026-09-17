#!/usr/bin/env bash
# 重新注册本机 wist-agentd 到 wist-gateway。
#
# 只修 agentd 侧：清掉失效凭据 → 签发新 enrollment token → 写回配置 → 重启 agentd。
# 网关本身无需重启（store 空是正常的，本来就没有 agent 注册）。
#
# 前置：gateway 已通过 ./sysrun/start.sh 启动（https://127.0.0.1:3000）。
#
# 用法：
#   ./sysrun/re-enroll.sh              # 后台重启 agentd
#   ./sysrun/re-enroll.sh --foreground # 前台跑 agentd（联调看日志）
#
# 可覆盖 env：
#   WIST_GATEWAY_HOME      网关数据 home（默认 ~/.wist-gateway）
#   WIST_GATEWAY_URL       网关地址（默认 https://127.0.0.1:3000）
#   WIST_AGENTD_HOME       agentd 配置+数据 home（默认 ~/.wist-agentd）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

GW_HOME="${WIST_GATEWAY_HOME:-${HOME}/.wist-gateway}"
GW_URL="${WIST_GATEWAY_URL:-https://127.0.0.1:3000}"
AGENTD_SCRIPT_DIR="${ROOT_DIR}/wist-agentd/sysrun"
AGENTD_HOME="${WIST_AGENTD_HOME:-${HOME}/.wist-agentd}"

FOREGROUND="${1:-}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd python3

CONFIG_FILE="${GW_HOME}/wist-gateway.toml"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "网关配置不存在：${CONFIG_FILE}" >&2
  echo "请先启动 gateway（wist-gateway-stack/sysrun/start.sh）生成配置。" >&2
  exit 1
fi

ADMIN_TOKEN="$(sed -n 's/^admin_api_token = "\(.*\)"/\1/p' "${CONFIG_FILE}")"
if [[ -z "${ADMIN_TOKEN}" ]]; then
  echo "无法从 ${CONFIG_FILE} 读取 admin_api_token" >&2
  exit 1
fi

echo "== 1. 签发新 enrollment token =="
ENROLL_TOKEN="$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${GW_URL%/}/api/v1/agent/install-code" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["bootstrap_enrollment_token"])')"
if [[ -z "${ENROLL_TOKEN}" ]]; then
  echo "签发 enrollment token 失败（检查 gateway 是否在跑、admin token 是否正确）" >&2
  exit 1
fi
echo "  token 前缀：${ENROLL_TOKEN:0:8}..."

echo "== 2. 清掉 agentd 旧身份 =="
rm -f "${AGENTD_HOME}/state/agent_runtime.json"
echo "  已删除 ${AGENTD_HOME}/state/agent_runtime.json"

echo "== 3. 写入 enrollment token 到 agentd.toml =="
python3 - "${ENROLL_TOKEN}" "${AGENTD_HOME}/agentd.toml" <<'PY'
import sys
token, path = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
out, inserted = [], False
for ln in lines:
    if ln.lstrip().startswith("enrollment_token"):
        continue
    out.append(ln)
    if ln.strip() == "[control_plane]" and not inserted:
        out.append(f'enrollment_token = "{token}"')
        inserted = True
open(path, "w").write("\n".join(out) + "\n")
PY
echo "  已写入 ${AGENTD_HOME}/agentd.toml"

echo "== 4. 重启 agentd =="
"${AGENTD_SCRIPT_DIR}/stop.sh"
if [[ "${FOREGROUND}" == "--foreground" ]]; then
  echo "  前台运行（Ctrl+C 停止）..."
  exec "${AGENTD_SCRIPT_DIR}/start.sh" --foreground
fi
"${AGENTD_SCRIPT_DIR}/start.sh"

echo
echo "完成。验证："
echo "  cat ${AGENTD_HOME}/state/agent_runtime.json       # 应有新的 wic_ 凭据"
echo "  python3 -m json.tool ${GW_HOME}/state/wist-gateway-store.json"
