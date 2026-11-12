#!/usr/bin/env bash
# 渲染 wist-harvest（云账号事实采集，**可选服务**）的运行配置。
#
# 为什么用脚本而不是 gx.tpl：数据源配置的渲染是**有条件**的 —— HARVEST_TENANT_ID 为空时
# 绝不能渲出一个「空租户」的数据源（那会真的去采，且租户字段是错的）。GXL 没有条件 tpl，
# 所以整块由脚本处理：没租户就**不生成**数据源，并说明启用方式。
#
# 渲染物（相对系统根）：
#   configs/harvest/harvest.toml                  服务配置（全局一份）
#   configs/harvest/sources.d/<source_code>.toml  数据源定义（有租户才有）
#
# 另外**创建** bind 挂载的宿主目录（harvest-run/{spool,state}）：必须在
# `gops sys perms --apply` 之前存在，否则 docker 会把它们建成 root:root，容器（999）写不动。
#
# 凭据不在渲染物里：配置只写「从哪个环境变量读」，值由 gops 从 .wist/sec-value.yml 注入。
set -euo pipefail

DIR="${1:-configs/harvest}"
RUN_DIR="${HARVEST_RUN_DIR:-./harvest-run}"

ten="${HARVEST_TENANT_ID:-}"
code="${HARVEST_SOURCE_CODE:-tencent-cloud-prod}"
envr="${HARVEST_ENV_REF:-prod}"
regions="${HARVEST_REGIONS:-auto}"

write_if_changed() { # $1=目标路径；stdin=内容
  local path="$1" tmp
  mkdir -p "$(dirname "${path}")"
  tmp="$(mktemp "${path}.XXXXXX")"
  cat >"${tmp}"
  if [[ -f "${path}" ]] && cmp -s "${tmp}" "${path}"; then
    rm -f "${tmp}"
    echo "  渲染值与当前一致，跳过：${path}"
  else
    chmod 644 "${tmp}"
    mv -f "${tmp}" "${path}"
    echo "  已写：${path}"
  fi
}

# ── ⓿ 宿主运行态目录（早于 perms 对齐，见文件头）──
mkdir -p "${RUN_DIR}/spool" "${RUN_DIR}/state"
echo "  已确保运行态目录：${RUN_DIR}/{spool,state}"

# 密钥：与网关共用 `.wist/sec-value.yml`（由 `gops sec` 维护，`:ro` 挂到容器 /secrets）。
# 这里只做**非阻断提示** —— 缺键时容器起来会因 healthcheck 失败暴露，不必在 localize 阶段拦住。
if [[ -f ./.wist/sec-value.yml ]]; then
  echo "  密钥文件就绪：./.wist/sec-value.yml（需要键 toc_secretid / toc_secretkey，gops sec list 可核对）"
else
  echo "  提示：./.wist/sec-value.yml 不存在 —— 启用云采集前必须写入："
  echo "         toc_secretid / toc_secretkey（用 gops sec 维护，模式 0640、属组=容器 gid）"
fi

# ── ① 服务配置 ──
# sink 指向同栈 wparse 的 harvest_1 source（容器内 9001，应用契约写死，见 data-plane/topology/sources/）。
# allow_plaintext：compose 内网、该 source 只开明文 TCP；不要把这个地址暴露到宿主。
write_if_changed "${DIR}/harvest.toml" <<TOML
# 由 scripts/init-harvest.sh 生成 —— 不要手改。
# 改 sys/setting/vars.yml（或 values/ 覆盖）后重新 \`gops sys localize\`。

[service]
# 收齐之前不发送：一个采集范围的完整快照先落盘，再一次性发出。
spool_dir = "/var/lib/wist-harvest/spool"
state_dir = "/var/lib/wist-harvest/state"
page_size = 100
# 单帧上限：超限即 Aborted（推动下游支持分片组装，不拆 snap_id）。
max_frame_bytes = 33554432
max_response_bytes = 16777216
request_timeout_ms = 30000
concurrency = 1
# 空 ≠ 失败：只有范围完整且云端确实为空时才允许发空快照。
allow_empty = false

[retry]
max_attempts = 4
base_delay_ms = 200
max_delay_ms = 5000

[rate]
default_qps = 5.0
default_burst = 5.0

[sink]
endpoint = "wparse:9001"
# 同栈内网明文（harvest_1 无 TLS）。不要改成对公网可达的地址。
allow_plaintext = true
connect_timeout_ms = 5000
ack_timeout_ms = 15000
publish_attempts = 3
TOML

# ── ② 数据源（无租户则不渲染，并清掉上一次的残留）──
src="${DIR}/sources.d/${code}.toml"
if [[ -z "${ten}" ]]; then
  [[ -f "${src}" ]] && { rm -f "${src}"; echo "  已移除数据源（HARVEST_TENANT_ID 为空）：${src}"; }
  echo "  跳过数据源渲染：HARVEST_TENANT_ID 未配置（云采集不启用）。"
  echo "  启用：values/ 里写 harvest_tenant_id（或 HARVEST_TENANT_ID），再跑 gops sys localize。"
  exit 0
fi

if [[ "${regions}" == "auto" ]]; then
  regions_line='regions = "auto"'
else
  list=""
  IFS=',' read -r -a parts <<<"${regions}"
  for p in "${parts[@]}"; do
    p="$(echo "${p}" | tr -d '[:space:]')"
    [[ -n "${p}" ]] || continue
    [[ -z "${list}" ]] && list="\"${p}\"" || list="${list}, \"${p}\""
  done
  [[ -n "${list}" ]] || { echo "错误：HARVEST_REGIONS 既不是 auto 也没有有效地域" >&2; exit 1; }
  regions_line="regions = [${list}]"
fi

write_if_changed "${src}" <<TOML
# 由 scripts/init-harvest.sh 生成 —— 不要手改。
#
# source_code 换实现（Java → Rust）**不能换**：下游按它做资源匹配与作用域隔离。

source_code = "${code}"
tenant_id = "${ten}"
group = "inventory"
env_ref = "${envr}"
${regions_line}

[assets]
cloud_host = true
eip = true
vpc = true
subnet = true

# 凭据只写「从哪读」，永远不写值。
# 与网关共用 .wist/sec-value.yml（扁平 YAML，gops sec 维护），:ro 挂进容器 /secrets。
# **不要**改成 env —— 那会让密钥出现在 docker inspect 里。
[credential]
secret_id = { file = "/secrets/sec-value.yml", field = "toc_secretid" }
secret_key = { file = "/secrets/sec-value.yml", field = "toc_secretkey" }
TOML
