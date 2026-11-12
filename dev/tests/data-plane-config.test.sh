#!/usr/bin/env bash
# 门禁：**本栈实际发布的那份** data-plane 配置必须能被当前 wparse 完整装载。
#
# 为什么单列一条（而不是并进 `agent-uplink-ivsrep.test.sh`）：
#   * 那条测试只放**一份** sink（ivsrep），验的是「报告这条路能通」；
#   * 站点拿到的却是 `sys/data-plane/` 整份 seed（6 个 sink 分组 + 全部模型）——
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

# 每个 sink 分组都在位（少一个 = 该类记录落进 `log_std`（`oml = ["*"]` 兜底）或直接丢）。
# 名字是 2026-11-11 统一命名后的：文件 `host_*` / `log_*`，分组名跟着文件走。
for name in agent-facts agent-dsnap host-metrics agent-ivsrep ignore log-raw log_std log_confused; do
  if ! grep -rqs "name = \"${name}\"" "${WORK}/topology/sinks"; then
    echo "[FAIL] 缺少 sink 分组：${name}" >&2
    exit 1
  fi
done

# `host-metrics` 分组的两个 sink 都在位：
#   1. 本地 JSONL 保底（排查窗口）—— 必须**带轮转**，否则文件无限长；
#   2. 通用 VM sink（`vm_metrics_sink`）写**本站** VictoriaMetrics —— 种子的出口只有「网关自己」，
#      计算区（field）那份 VM 由站点 infra 仓加，不进共享种子
#      （见 `sinks-no-field-delivery.test.sh`）。
# 注意：轮转三键必须先出现在连接器的 `allow_override` 里，否则装载直接失败（exit 300）。
# 注：配置里的注释也提到这些名字，所以先把注释剔掉再判。
METRICS_SINK="${WORK}/topology/sinks/business.d/host_metrics.toml"
METRICS_CFG="$(sed 's/#.*//' "${METRICS_SINK}")"
for need in 'connect = "file_json_sink"' 'connect = "vm_metrics_sink"' \
            'max_size' 'max_rolls' 'roll_compress'; do
  if [[ "${METRICS_CFG}" != *"${need}"* ]]; then
    echo "[FAIL] host-metrics 分组缺少 ${need}（文件 sink 无轮转会无限长 / 本站 VM sink 没了自观测就断了）" >&2
    exit 1
  fi
done

# 报告落点必须是**连接器默认目录**（`./data/out_dat`），即本分组不覆写 `base`：
# 网关按 `report_dir`（stack 缺省 `data/out_dat`）读目录，两侧改一边就会让「主机 → 调查」页恒空。
IVSREP_SINK="${WORK}/topology/sinks/business.d/agent_ivsrep.toml"
if grep -qs '^\s*base\s*=' "${IVSREP_SINK}"; then
  echo '[FAIL] agent_ivsrep sink 不该覆写 base（应落到连接器默认的 ./data/out_dat）' >&2
  exit 1
fi
if ! grep -qs '^file = "agent-ivsrep.jsonl"$' "${IVSREP_SINK}"; then
  echo '[FAIL] agent_ivsrep sink 的输出文件名不是 agent-ivsrep.jsonl' >&2
  exit 1
fi
# `agent_ivsrep` 例外：**不轮转**（`max_rolls = 0`，只留 `max_size` 让轮转键成组、能过校验）。
# 网关直接从 `data/out_dat` 读报告文件，轮转后名字带 `.gz`/序号 → 「主机 → 调查」页恒空（踩过）。
if ! grep -qs '^max_rolls = 0$' "${IVSREP_SINK}"; then
  echo '[FAIL] agent_ivsrep sink 必须不轮转（max_rolls = 0）：网关按文件名读 out_dat，轮转后页面恒空' >&2
  exit 1
fi

# 计算区数据场（field）的三个写入端点必须以**连接器**形态留在种子里（能力），
# 但种子 sink **不得引用**它们 —— 投递是站点的配置，见 `sinks-no-field-delivery.test.sh`。
for id in wist-field-evidence wist-field-atlas wist-field-metrics; do
  if ! grep -rqs "id = \"${id}\"" "${WORK}/connectors/sink.d"; then
    echo "[FAIL] 缺少连接器：${id}" >&2
    exit 1
  fi
done

# 反向：种子 sink 里不该出现 field 端点变量（端点属于站点，不进共享种子）。
# 只看真正生效的行：注释里提到变量名不算。
for pattern in FIELD_EVIDENCE_URL FIELD_ATLAS_URL FIELD_METRICS_URL; do
  if grep -rqs "^[^#]*${pattern}" "${WORK}/topology/sinks"; then
    echo "[FAIL] 种子 sink 里出现 ${pattern}：field 投递属于站点 infra 仓（wp-infra-*），不进共享种子" >&2
    exit 1
  fi
done

# 旧变量名已移除：残留引用会静默走缺省地址（数据投到错的机器上也不报错）。
# 同样只看生效行（注释里写「旧名已移除」不算残留）。
for legacy in EVIDENCE_SINK_URL ATLAS_SINK_URL CONSOLE_VM_ENDPOINT; do
  if grep -rqs "^[^#]*${legacy}" "${WORK}/connectors" "${WORK}/topology"; then
    echo "[FAIL] 配置里还引用已移除的旧变量 ${legacy}：改用 FIELD_*_URL" >&2
    exit 1
  fi
done

echo "data-plane config test passed"
