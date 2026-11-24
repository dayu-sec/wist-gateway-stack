#!/usr/bin/env bash
# 数据面配置自检（**判据在引擎**：`wparse check`，见 wp-labs/warp-parse#375）。
#
# 跑一次性的命令行容器：只读挂载、无网络、跑完即删。检查两棵树：
#   · 种子 `sys/data-plane`（随包发布；CI 也用它）
#   · 工作根 `data-plane-run/work`（存在才查）—— `cp -R --update=none` 叠加后的**现状**
#
# 为什么不是「进正在跑的容器里查」：升级事务的顺序是 regenerate(本地化) → pull → up，
# 验配置时跑着的还是**旧镜像 + 旧工作根**，而要判的是「新种子 + 工作根现状」；
# 宿主一般也没有 wparse 二进制。所以借一次性容器，用**新镜像自己的 CLI**（判据只有一份）。
#
# 判定：两个 `sink_group` 绑同一个 `oml` matcher 时引擎不报错、只静默丢 OML 富化
# （下游拿 WPL 原始字段；VM 回 204 一条序列都不建）。2026-11-12 现场因此断流 6 天。
# 本脚本发现即 **exit 1** —— localize ⑦ 失败 → `gops prj upgrade` 回滚。
#
# 特性探测：镜像里的 wparse 还没有 `check` 子命令时打印跳过并 exit 0
# （把 `WPARSE_TAG` 升到带 #375 的版本后自动生效，不需要再改本脚本）。
#
# 用法：
#   ./scripts/check-data-plane.sh [--image <ref>] [--seed <dir>] [--work <dir>]
#   CI 用公开源：--image ghcr.io/wp-labs/warp-parse:<WPARSE_TAG>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env"

image=""
seed="${ROOT}/sys/data-plane"
work="${ROOT}/data-plane-run/work"

while [ $# -gt 0 ]; do
  case "$1" in
    --image) image="${2:?--image 需要一个值}"; shift 2 ;;
    --seed) seed="${2:?--seed 需要一个值}"; shift 2 ;;
    --work) work="${2:?--work 需要一个值}"; shift 2 ;;
    -h | --help)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^#\{1\} \{0,1\}//'
      exit 0
      ;;
    *)
      echo "未知参数：$1（见 --help）" >&2
      exit 2
      ;;
  esac
done

env_get() { # $1=KEY（`.env` 不存在/没这个键时输出空）
  [ -f "${ENV_FILE}" ] || return 0
  sed -n "s/^$1=//p" "${ENV_FILE}" | head -n 1 | sed -e 's/^"//' -e 's/"$//'
}

# 没有 docker（或 daemon 没起）就没法跑引擎的判据：本地开发不该被拦，但要**说出来**。
# 部署机上 ⑥ `gops sys perms --apply` 已经用过 compose，daemon 一定在 —— 这里不会误跳过。
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "skip: 本机 docker 不可用（没装 / daemon 没起），跳过数据面配置检查（localize ⑦ 与 CI 会跑）"
  exit 0
fi

if [ -z "${image}" ]; then
  spc="$(env_get WARP_SPC)"
  tag="$(env_get WPARSE_TAG)"
  if [ -z "${spc}" ] || [ -z "${tag}" ]; then
    echo "错误：.env 里缺 WARP_SPC / WPARSE_TAG，解析不到镜像；先 \`gops sys localize\`，或用 --image 指定" >&2
    exit 1
  fi
  image="${spc}/warp-parse:${tag}"
fi
echo "== 数据面配置检查：${image}"

if ! docker image inspect "${image}" >/dev/null 2>&1; then
  echo "   本机没有该镜像，先拉取（与升级的 pull 共用缓存）"
  if ! docker pull "${image}" >/dev/null; then
    echo "错误：镜像拉不下来，无法验证数据面配置（部署时同样缺它）：${image}" >&2
    exit 1
  fi
fi

# 判据读的 `${VAR}` 与运行时同源：把整份 `.env` 传进去（种子里的 ${...} 才不会按空值装载）。
env_flag=""
if [ -f "${ENV_FILE}" ]; then
  env_flag="--env-file ${ENV_FILE}"
fi

# 这两个端点**只由 compose 注入**（不在 .env / vars 里）：`wparse check` 要判 `http.endpoint`
# 是不是 http(s)，解析不到就会以配置错误直接失败（0.19.11 升级到 0.37.0-alpha 时第一次暴露）。
# 值与 `sys/docker-compose.yml` 的 wparse 服务一致；调用方显式设了就以调用方为准。
endpoint_flags=(
  -e "WPARSE_VM_ENDPOINT=${WPARSE_VM_ENDPOINT:-http://victoria-metrics:8428}"
  -e "WPARSE_GATEWAY_ENDPOINT=${WPARSE_GATEWAY_ENDPOINT:-http://gateway:3001}"
)

# 特性探测：没有 `check` 子命令的老镜像直接跳过（不阻塞升级，也不再需要改脚本）。
# shellcheck disable=SC2086  # env_flag 为空时要整段消失
if ! docker run --rm --network none --entrypoint wparse ${env_flag} \
  "${image}" check --help >/dev/null 2>&1; then
  echo "skip: 该镜像的 wparse 还没有 check 子命令（wp-labs/warp-parse#375）；升 WPARSE_TAG 后自动生效"
  exit 0
fi

run_check() { # $1=宿主目录 $2=容器内挂载点 $3=说明
  echo "   - $3：$1"
  local rc=0
  # shellcheck disable=SC2086  # env_flag 同上
  docker run --rm --network none --entrypoint wparse ${env_flag} "${endpoint_flags[@]}" \
    -v "$1:$2:ro" "${image}" check --work-root "$2" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    # 退出码要分开说：`1` 是语义问题（重复 matcher 那类，会静默丢富化），
    # `2` 是配置加载失败（${VAR} 解析不到 / endpoint 不是 http(s) / local.toml 写错）。
    # 原先一律说成“同一个 oml matcher 被两个组绑定”，把配置错误也误报成语义问题。
    case "${rc}" in
      1)
        echo "错误：数据面配置有语义问题（check 退出码 1）—— 常见：同一个 oml matcher 被两个 sink 分组绑定（引擎不报错、只静默丢 OML 富化）" >&2
        ;;
      2)
        echo "错误：数据面配置加载失败（check 退出码 2）—— 常见：\${VAR} 解析不到 / endpoint 不是 http(s) / wparse.local.toml 写错" >&2
        ;;
      *)
        echo "错误：数据面配置检查未通过（check 退出码 ${rc}）" >&2
        ;;
    esac
    echo "      处置：按上面引擎输出改配置——种子与工作根都要改，再重跑" >&2
    exit 1
  fi
}

run_check "${seed}" /check "种子（随包发布）"
if [ -d "${work}" ]; then
  run_check "${work}" /work "运行态工作根（含历史残留）"
else
  echo "   - 工作根不存在（首次安装 / 还没起过容器），跳过：${work}"
fi

echo "== 数据面配置检查通过"
