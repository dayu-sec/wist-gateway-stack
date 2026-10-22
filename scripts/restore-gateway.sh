#!/usr/bin/env bash
# 恢复网关的**身份与（按需的）管理面状态**到目标目录 —— 典型场景：**在新机器**上用别处带来的备份重建。
#
# 备份条目相对**栈根**（见 `backup-gateway.sh`）：身份 PEM 在 `identity/gateway/{public,private}`，
# 资源（配置 / 库）在 `configs/gateway/` —— 所以解包目标也应给**栈根**（默认 `.`），条目按原相对路径落回。
#
# 解包内容取决于备份级别（见 `backup-gateway.sh --level`）：可重建级 = 身份 PEM + 渲染好的
# `wist-gateway.toml`；可还原级再带 `wist-gateway.value.json` 与 SQLite 库。库里存着 agent 的
# **凭据**（bearer token / 客户端证书）——要「老 agent 无感连上」就得把它带上（见 `--no-config`）。
#
# 用法：
#   scripts/restore-gateway.sh <备份文件> [--to <栈根>] [--pem-only|--no-config] [--force] [--restart]
#
#   <备份文件>   scripts/backup-gateway.sh 产出的 .tar.gz
#   --to <栈根>  解包目标（默认 `.`，即栈根；条目相对栈根，别给 `configs/gateway`）
#   --pem-only   只恢复 **PEM**（CA / 叶证书 / 私钥，即 `identity/**/*.pem`）；跳过 toml / value.json / 库
#   --no-config  恢复除**配置**（`configs/gateway/wist-gateway.{toml,value.json}`）外的一切 = 身份 PEM + SQLite 库
#   --force      覆盖目标里已存在的同名文件（默认拒绝）
#   --restart    解包后重启网关（走 stack 根的 compose：docker compose … restart gateway）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE=(docker compose --project-directory "${STACK_ROOT}" -f "${STACK_ROOT}/sys/docker-compose.yml")

DEFAULT_DIR="."   # 默认解包到栈根：条目相对栈根（见头注释）
FILE=""
TO=""
FORCE=0
RESTART=0
PEM_ONLY=0
NO_CONFIG=0

die() {
  echo "错误：$*" >&2
  exit 1
}

abspath() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$1")") || printf '%s\n' "$1"; }

usage() {
  # 打印文件头的**注释块**（第 2 行起，到首个非注释行为止）：加/删注释行都不用改行号。
  awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)
      [[ -n "${2:-}" ]] || die "--to 需要一个目标目录"
      TO="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --restart)
      RESTART=1
      shift
      ;;
    --pem-only)
      PEM_ONLY=1
      shift
      ;;
    --no-config)
      NO_CONFIG=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "未知参数：$1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

FILE="${positional[0]:-}"
[[ -n "${FILE}" ]] || {
  usage >&2
  die "用法：$0 <备份文件> [--to <栈根>] [--pem-only|--no-config] [--force] [--restart]"
}
[[ "${PEM_ONLY}" == "1" && "${NO_CONFIG}" == "1" ]] && die "--pem-only 与 --no-config 只能二选一"
[[ -f "${FILE}" ]] || die "找不到备份文件：${FILE}"
DEST="${TO:-${positional[1]:-${DEFAULT_DIR}}}"

# 目标根不存在就先建；`identity/...`、`configs/gateway/...` 的中间目录由 tar 解包时自建。
mkdir -p "${DEST}"

# 选取要恢复的条目（跳过目录项）。两种过滤：
#   --pem-only  只留 `.pem`（身份材料；条目形如 `identity/gateway/private/*.pem`，按后缀判即可）；
#   --no-config 丢掉**配置**（`configs/gateway/wist-gateway.toml` 与 `.value.json`），其余（身份 PEM + SQLite 库）全要。
entries=()
skipped=()
entry=""
while IFS= read -r entry; do
  [[ "${entry}" == */ ]] && continue
  if [[ "${PEM_ONLY}" == "1" && "${entry}" != *.pem ]]; then
    skipped+=("${entry}")
    continue
  fi
  if [[ "${NO_CONFIG}" == "1" ]]; then
    case "${entry}" in
      configs/gateway/wist-gateway.toml | configs/gateway/wist-gateway.value.json | */configs/gateway/wist-gateway.toml | */configs/gateway/wist-gateway.value.json)
        skipped+=("${entry}")
        continue
        ;;
    esac
  fi
  entries+=("${entry}")
done < <(tar -tzf "${FILE}")

if [[ ${#entries[@]} -eq 0 ]]; then
  if [[ "${PEM_ONLY}" == "1" ]]; then
    die "备份里没有 .pem，--pem-only 无可恢复项：${FILE}"
  fi
  die "备份是空的：${FILE}"
fi

# 安全：默认不覆盖已有文件（避免把在用的身份材料糊掉）。只检查**本次要恢复**的条目。
if [[ "${FORCE}" != "1" ]]; then
  for entry in "${entries[@]}"; do
    [[ -e "${DEST}/${entry}" ]] && die "目标已存在：${DEST}/${entry}（要覆盖加 --force）"
  done
fi

tar -xzf "${FILE}" -C "${DEST}" "${entries[@]}"
echo "已恢复 → $(abspath "${DEST}")"
if [[ "${PEM_ONLY}" == "1" ]]; then
  echo "  模式：仅 PEM（身份材料）；跳过 ${#skipped[@]} 个非 PEM 文件（toml / value.json / 库等，目标现有的原样保留）"
elif [[ "${NO_CONFIG}" == "1" ]]; then
  echo "  模式：身份 + 管理面状态（不含配置）；跳过 ${#skipped[@]} 个配置文件（toml / value.json，目标现有的原样保留）"
fi
echo "  内容："
printf '    %s\n' "${entries[@]}"
if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "  跳过："
  printf '    %s\n' "${skipped[@]}"
fi
echo
if [[ "${PEM_ONLY}" == "1" ]]; then
  echo "  注意：本次**没带库**。agent 的凭据（bearer token / 客户端证书）存在库里，"
  echo "        老 agent 会因认不出凭据而 **401** —— 要么重装 agent，要么改用 --no-config 连库一起搬。"
else
  echo "  agent 身份：库里有 agent 的凭据，老 agent 重连即可（无需重装）。"
fi

# 恢复出来的文件属主/属组是「解包账号」，**不是**容器 gid（tar 以非 root 解包无法保留属主）——
# 不对齐的话，发布态网关读不到私钥（症状与首次安装的 Permission denied 一模一样）。
# 这一步幂等，且只动属主/属组/权限，不碰内容。只在目标是**栈根**时自动跑（对齐脚本以栈根为参数）。
if [[ "$(abspath "${DEST}")" == "${STACK_ROOT}" ]]; then
  echo
  echo "  对齐宿主属主/权限（容器以 999:999 运行）："
  if command -v gops >/dev/null 2>&1 && gops sys perms --help >/dev/null 2>&1; then
    # gops ≥ 2.7：从 compose 派生（含**挂载拆分**后的 ro/rw 语义，比按文件名列举更准）
    ( cd "${STACK_ROOT}" && gops sys perms --apply ) ||
      echo "  提示：属主对齐未完成，网关可能读不到私钥，请执行：cd ${STACK_ROOT} && gops sys perms --apply" >&2
  else
    echo "  错误：本栈需要 gops ≥ 2.7（gops sys perms）。恢复后请升级 gops 再执行：" >&2
    echo "    cd ${STACK_ROOT} && gops sys perms --apply" >&2
  fi
fi

if [[ "${RESTART}" == "1" ]]; then
  if [[ -f "${STACK_ROOT}/sys/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "  重启发布态网关（${COMPOSE[*]} restart gateway）…"
    "${COMPOSE[@]}" restart gateway
    echo "  已重启。"
  else
    echo "  跳过 --restart：docker 不可用（或容器后端没起）。" >&2
  fi
else
  echo "  下一步：重启网关让新配置/证书生效 ——"
  echo "    发布态：${COMPOSE[*]} restart gateway"
  echo "    开发态：./dev/svc.sh stop gateway && ./dev/svc.sh start gateway"
fi

# 恢复后自检：**只读**。上一步只保证「文件写回去了」，不保证它们互相一致
# （例如恢复的是半套：gwlinkd.toml 指向的投放目录对不上、渲染产物比 value.json 旧）。
# 不改变退出码 —— 恢复本身已经完成，这里只把矛盾**当场**报出来，而不是等下次 localize。
if [[ "$(abspath "${DEST}")" == "${STACK_ROOT}" && -x "${STACK_ROOT}/scripts/check-stack.sh" ]]; then
  echo
  echo "  恢复后自检（`scripts/check-stack.sh`）："
  if selfcheck_out="$("${STACK_ROOT}/scripts/check-stack.sh" 2>&1)"; then
    echo "    通过（无 WARN / FAIL）"
  else
    printf '%s\n' "${selfcheck_out}" | sed 's/^/    /'
    echo "    ↑ 不影响本次恢复结果；按提示处理后跑一次 \`gops sys localize\`。"
  fi
fi
