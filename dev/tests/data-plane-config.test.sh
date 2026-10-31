#!/usr/bin/env bash
# 门禁：**本栈实际发布的那份** data-plane 配置必须能被当前 wparse 完整装载。
#
# 为什么单列一条（而不是并进 `agent-uplink-ivsrep.test.sh`）：
#   * 那条测试只放**一份** sink（ivsrep），验的是「报告这条路能通」；
#   * 站点拿到的却是 `sys/data-plane/` 整份 seed（7 个 sink 分组 + 全部模型）——
#     任何一个参数写错（例如这个引擎不支持的 `max_size` / `roll_compress`），
#     `load sink route confs` 会整体失败，表现是「引擎起来了但一条数据都没有」，比崩溃更难查。
#
# 跑法：`dev/tests/data-plane-config.test.sh`（需要 dev/bin/wparse；缺了跳过，不阻断开发机）。
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
# 不继承真实运行目录里的锁 / 旧输出，保证可重复。
rm -rf "${WORK}/.run" "${WORK}/data"
# 管理面配置在项目根 `wparse.local.toml`；batch 不启管理面。
rm -f "${WORK}/wparse.local.toml"

# 只留一个**空**的 file source：本门禁只关心「配置能不能装载」，不关心解析结果。
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
: > "${WORK}/data/in_dat/gen.dat"

# 站点上这些变量由 compose 注入；缺了会让「引用了 ${...} 的 sink」判成配置错误，
# 那是**部署时**的问题，不该在本门禁里伪装成配置写错。
export WPARSE_GATEWAY_ENDPOINT="${WPARSE_GATEWAY_ENDPOINT:-http://127.0.0.1:3001}"
export WPARSE_VM_ENDPOINT="${WPARSE_VM_ENDPOINT:-http://127.0.0.1:8428}"
export WPARSE_PROJECT_MODELS_REPO="${WPARSE_PROJECT_MODELS_REPO:-}"
export WPARSE_PROJECT_INFRA_REPO="${WPARSE_PROJECT_INFRA_REPO:-}"

LOG="${TMP}/wparse.log"
if ! "${WPARSE}" batch --work-root "${WORK}" >"${LOG}" 2>&1; then
  echo "[FAIL] 发布态 data-plane 配置装载失败（见下）" >&2
  sed -n '1,40p' "${LOG}" >&2
  exit 1
fi

# 引擎会打很多 `vars not value : …` 噪声；真正的失败标志是 ERROR 行。
if grep -q 'ERROR' "${LOG}"; then
  echo "[FAIL] 日志里出现 ERROR（配置装载通过但运行期报错）" >&2
  grep -n 'ERROR' "${LOG}" >&2
  exit 1
fi

# 每个 sink 分组都在位（少一个 = 某类数据会静默落兜底 sink 或直接丢）。
for name in gateway-logs gateway-raw-logs agent-facts agent-dsnap agent-metrics agent-ivsrep ignore; do
  if ! grep -rqs "name = \"${name}\"" "${WORK}/topology/sinks"; then
    echo "[FAIL] 缺少 sink 分组：${name}" >&2
    exit 1
  fi
done

# 报告目录必须是 `data/ivsrep`（网关按 `<work_dir>/data/ivsrep` 推导，改了这条要同时改网关）。
if ! grep -qs 'base = "./data/ivsrep/"' "${WORK}/topology/sinks/business.d/agent_ivsrep.toml"; then
  echo '[FAIL] agent_ivsrep sink 的落点不是 ./data/ivsrep/' >&2
  exit 1
fi

echo "data-plane config test passed"
