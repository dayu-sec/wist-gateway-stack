#!/usr/bin/env bash
# 备份网关的**身份与运行状态**。备份分**两级**，用 `--level` 选；恢复见 `restore-gateway.sh`。
#
# 级别：
#   - `rebuild`（可重建级，**默认**）：把网关**重新立起来**所需的全部 —— 身份 PEM（网关 CA = 信任锚，
#     丢了 = 全队 agent 重装；agent CA；服务端叶证书；安装脚本签名密钥）＋ 渲染好的 `wist-gateway.toml`。
#     恢复后**直接起网关即可**，不必再跑 localize 渲染。
#   - `restore`（可还原级）：在可重建级之上，再带 `wist-gateway.value.json`（渲染源，保住原 admin token /
#     `package_file`）与 **SQLite 库** —— 按原样还原管理面状态（派活 / 安装包录入 / 用途与上送绑定等）。
#
# 两级都**不含**（都可重生成/重导入）：指标历史（VictoriaMetrics 卷，随时间贬值）、安装包缓存、
# 页面证书（`configs/web/tls/`）、`configs/gateway/content/`。
#
# 用法：
#   scripts/backup-gateway.sh [--level rebuild|restore] [--from <源目录>] [--to <输出文件>]
#   scripts/backup-gateway.sh check [--level rebuild|restore] [--from <源目录>]
#   scripts/backup-gateway.sh list  [备份文件|目录]     # 列已备份的归档；给了归档文件则列其内容
#
# 参数：
#   --level <级别>   rebuild（可重建级，默认）| restore（可还原级）
#   --from <目录>    备份的**源目录**（默认 configs/gateway；开发态传 ~/.wist-gateway）
#   --to <文件>      输出文件（默认 ./wist-gateway-backup-<时间戳>.tar.gz）
#
# 恢复用独立脚本：scripts/restore-gateway.sh <备份文件> [--to <目标目录>] [--force] [--restart]
# 输出含私钥：请落到**安全且离机**的位置（脚本把产物权限设为 0600）。
set -euo pipefail

CMD="backup"
CONFIG_DIR=""
OUT=""
LEVEL="rebuild"

DEFAULT_CONFIG_DIR="configs/gateway"
LEVELS="rebuild restore"

die() {
  echo "错误：$*" >&2
  exit 1
}

abspath() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$1")") || printf '%s\n' "$1"; }

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^#[[:space:]]\{0,1\}//'
}

level_label() {
  case "$1" in
    rebuild) echo "可重建级" ;;
    restore) echo "可还原级" ;;
    *) echo "$1" ;;
  esac
}

# 会进备份的相对路径（相对 config_dir；只收**存在**的）。
#   可重建级：身份 PEM + 渲染好的 wist-gateway.toml。
#   可还原级：再 + 渲染源 value.json + SQLite 库。
collect_files() {
  local dir="$1" rel f
  for rel in \
    state/gateway-ca.crt.pem state/gateway-ca.key.pem \
    state/agent-ca.crt.pem state/agent-ca.key.pem \
    state/admin-tls.crt.pem state/admin-tls.key.pem \
    state/install-script-signing-ed25519.pkcs8.pem \
    wist-gateway.toml; do
    [[ -e "${dir}/${rel}" ]] && printf '%s\n' "${rel}"
  done
  if [[ "${LEVEL}" == "restore" ]]; then
    for rel in wist-gateway.value.json; do
      [[ -e "${dir}/${rel}" ]] && printf '%s\n' "${rel}"
    done
    for f in "${dir}"/state/*.db "${dir}"/state/*.db-wal "${dir}"/state/*.db-shm; do
      [[ -e "${f}" ]] && printf '%s\n' "state/$(basename "${f}")"
    done
  fi
}

do_backup() {
  local dir="$1" out="$2"
  [[ -d "${dir}" ]] || die "找不到源目录：${dir}（先跑 init-gateway / 起一次网关生成；开发态传 --from ~/.wist-gateway）"
  local files=() f
  while IFS= read -r f; do [[ -n "${f}" ]] && files+=("${f}"); done < <(collect_files "${dir}")
  [[ ${#files[@]} -gt 0 ]] || die "${dir} 下没有任何可备份的身份/配置文件"

  tar -czf "${out}" -C "${dir}" "${files[@]}"
  chmod 600 "${out}" 2>/dev/null || true

  echo "已备份（$(level_label "${LEVEL}")）→ ${out}"
  echo "  源目录：$(abspath "${dir}")"
  echo "  内容："
  printf '    %s\n' "${files[@]}"
  if [[ ! -e "${dir}/state/gateway-ca.key.pem" ]]; then
    echo "  注意：未找到网关 CA 私钥 —— 若这台还没建 CA，备份不含信任锚。" >&2
  fi
  if [[ "${LEVEL}" == "rebuild" ]]; then
    echo
    echo "  可重建级含身份 PEM + 渲染好的 toml；要连渲染源 value.json 与 SQLite 库（按原样还原管理面状态）用 --level restore。"
  fi
  echo
  echo "  输出含私钥，请保管到**安全且离机**的位置。"
}

do_check() {
  local dir="$1"
  [[ -d "${dir}" ]] || die "找不到源目录：${dir}"
  echo "会被备份的件（$(level_label "${LEVEL}")；源目录 $(abspath "${dir}")）："
  local f any=0
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    printf '  %s\n' "${f}"
    any=1
  done < <(collect_files "${dir}")
  [[ "${any}" == "1" ]] || echo "  （无）"
}

# 列“已备份的文件”：给了归档文件就列它里面有哪些件；否则在目录里找 wist-gateway-backup-*.tar.gz。
do_list() {
  local arg="${1:-}"
  if [[ -n "${arg}" && -f "${arg}" ]]; then
    echo "备份归档：$(abspath "${arg}")（$(ls -lh "${arg}" | awk '{print $5}')）"
    echo "  内容："
    tar -tzf "${arg}" | sed 's/^/    /'
    return 0
  fi
  local dir="${arg:-.}"
  [[ -d "${dir}" ]] || die "不是文件也不是目录：${arg}"
  echo "已备份的归档（${dir}）："
  local found=0 f
  for f in "${dir}"/wist-gateway-backup-*.tar.gz; do
    [[ -e "${f}" ]] || continue
    found=1
    printf '  %-58s %8s  %s\n' "$(basename "${f}")" "$(ls -lh "${f}" | awk '{print $5}')" "$(date -r "${f}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '')"
  done
  if [[ "${found}" == "0" ]]; then
    echo "  （无。先跑：./scripts/backup-gateway.sh --from configs/gateway）"
  else
    echo "  （看某个归档里的件：$0 list <备份文件>）"
  fi
}

# ── 解析参数 ──
# 子命令可省：首参不是 backup/check/restore/list（而是 flag 或位置参数）时就当 backup。
case "${1:-}" in
  backup | check | restore | list)
    CMD="$1"
    shift
    ;;
esac
FROM=""
TO=""
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level)
      case "${2:-}" in
        rebuild | restore) LEVEL="$2" ;;
        *) die "--level 只接受：${LEVELS}" ;;
      esac
      shift 2
      ;;
    --from)
      [[ -n "${2:-}" ]] || die "--from 需要一个源目录"
      FROM="$2"
      shift 2
      ;;
    --to)
      [[ -n "${2:-}" ]] || die "--to 需要一个路径"
      TO="$2"
      shift 2
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

case "${CMD}" in
  backup)
    CONFIG_DIR="${FROM:-${positional[0]:-${DEFAULT_CONFIG_DIR}}}"
    OUT="${TO:-${positional[1]:-}}"
    [[ -n "${OUT}" ]] || OUT="./wist-gateway-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    do_backup "${CONFIG_DIR}" "${OUT}"
    ;;
  restore)
    usage >&2
    die "恢复请用另一个脚本：scripts/restore-gateway.sh <备份文件> [--to <目标目录>] [--force] [--restart]"
    ;;
  check)
    CONFIG_DIR="${FROM:-${positional[0]:-${DEFAULT_CONFIG_DIR}}}"
    do_check "${CONFIG_DIR}"
    ;;
  list)
    do_list "${positional[0]:-${FROM:-}}"
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    die "未知子命令：${CMD}（可用：backup | check | list）"
    ;;
esac
