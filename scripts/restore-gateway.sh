#!/usr/bin/env bash
# 恢复网关的**身份与配置**（PEM）到目标目录 —— 典型场景：**在新机器**上用别处带来的备份重建。
#
# 只恢复身份文件（PEM）；数据库/历史不在备份里、也不需要：重启网关后，持有效客户端证书的
# agent 会**自动重新登记**。
#
# 用法：
#   scripts/restore-gateway.sh <备份文件> [--to <配置目录>] [--force] [--restart]
#
#   <备份文件>   scripts/backup-gateway.sh 产出的 .tar.gz
#   --to <目录>  解包目标（默认 configs/gateway；开发态传 ~/.wist-gateway）
#   --force      覆盖目标里已存在的同名文件（默认拒绝）
#   --restart    解包后重启网关（走 stack 根的 compose：docker compose … restart gateway）
#
# 恢复后：持有效证书的 agent 自动回来，无需逐台重装；页面证书、安装包缓存可重新生成/导入（不在备份里）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE=(docker compose --project-directory "${STACK_ROOT}" -f "${STACK_ROOT}/sys/docker-compose.yml")

DEFAULT_DIR="configs/gateway"
FILE=""
TO=""
FORCE=0
RESTART=0

die() {
  echo "错误：$*" >&2
  exit 1
}

abspath() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$1")") || printf '%s\n' "$1"; }

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^#[[:space:]]\{0,1\}//'
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
  die "用法：$0 <备份文件> [--to <配置目录>] [--force] [--restart]"
}
[[ -f "${FILE}" ]] || die "找不到备份文件：${FILE}"
DEST="${TO:-${positional[1]:-${DEFAULT_DIR}}}"

mkdir -p "${DEST}/state"

# 安全：默认不覆盖已有文件（避免把在用的身份材料糊掉）。
if [[ "${FORCE}" != "1" ]]; then
  entry=""
  while IFS= read -r entry; do
    [[ "${entry}" == */ ]] && continue
    [[ -e "${DEST}/${entry}" ]] && die "目标已存在：${DEST}/${entry}（要覆盖加 --force）"
  done < <(tar -tzf "${FILE}")
fi

tar -xzf "${FILE}" -C "${DEST}"
echo "已恢复 → $(abspath "${DEST}")"
echo "  内容："
tar -tzf "${FILE}" | sed 's/^/    /'
echo
echo "  agent 身份：持有效客户端证书的 agent 会在重连时**自动重新登记**，无需人工。"

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
