#!/usr/bin/env bash
# 备份网关的**身份与配置**（不可再生的 PEM）。默认**不含数据库与历史数据**；恢复见 `restore-gateway.sh`。
#
# 口径（与 mTLS 身份模型一致）：
#   - **要备份**的是 PEM：网关 CA（信任锚 —— 丢了 = 全队 agent 重装）、叶证书、安装脚本签名密钥、
#     agent CA（若开了 mTLS 签发）；外加 `wist-gateway.value.json` 与渲染出的 `wist-gateway.toml`。
#   - **不用备份**数据库与历史数据：SQLite 里的 agent 注册会在 agent 重连时由 mTLS **自动重建**；
#     指标历史随时间贬值。只有想保留**管理面状态**（派活 / 安装包录入记录 / 用途与上送绑定等）才加 `--with-store`。
#   - 页面证书（`configs/web/tls/`）可重新生成（浏览器重新信任即可）；安装包缓存可重新录入 —— 都不备份。
#
# 用法：
#   scripts/backup-gateway.sh [backup] [--from <源目录>] [--to <输出文件>] [--with-store]
#   scripts/backup-gateway.sh check [--from <源目录>]
#
# 参数：
#   --from <目录>   备份的**源目录**（默认 configs/gateway；开发态传 ~/.wist-gateway）
#   --to <文件>     backup 的输出文件（默认 ./wist-gateway-identity-<时间戳>.tar.gz）
#   --with-store    连同 SQLite 库一起（保留管理面状态）
#
# 也接受位置参数：scripts/backup-gateway.sh backup [源目录] [输出文件]
#
# 恢复用独立脚本：scripts/restore-gateway.sh <备份文件> [--to <目标目录>] [--force] [--restart]
#
# 输出含私钥：请落到**安全且离机**的位置（脚本把产物权限设为 0600）。
set -euo pipefail

CMD="backup"
CONFIG_DIR=""
OUT=""
WITH_STORE=0

DEFAULT_CONFIG_DIR="configs/gateway"

die() {
  echo "错误：$*" >&2
  exit 1
}

abspath() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$1")") || printf '%s\n' "$1"; }

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^#[[:space:]]\{0,1\}//'
}

# 会进备份的相对路径（相对 config_dir；只收**存在**的）。
collect_files() {
  local dir="$1" with_store="$2" rel f
  for rel in \
    state/gateway-ca.crt.pem state/gateway-ca.key.pem \
    state/agent-ca.crt.pem state/agent-ca.key.pem \
    state/admin-tls.crt.pem state/admin-tls.key.pem \
    state/dev-ca.crt.pem state/dev-ca.key.pem \
    state/install-script-signing-ed25519.pkcs8.pem \
    wist-gateway.toml wist-gateway.value.json; do
    [[ -e "${dir}/${rel}" ]] && printf '%s\n' "${rel}"
  done
  if [[ "${with_store}" == "1" ]]; then
    for f in "${dir}"/state/*.db "${dir}"/state/*.db-wal "${dir}"/state/*.db-shm; do
      [[ -e "${f}" ]] && printf '%s\n' "state/$(basename "${f}")"
    done
  fi
}

do_backup() {
  local dir="$1" out="$2"
  [[ -d "${dir}" ]] || die "找不到源目录：${dir}（先跑 init-gateway / 起一次网关生成；开发态传 --from ~/.wist-gateway）"
  local files=() f
  while IFS= read -r f; do [[ -n "${f}" ]] && files+=("${f}"); done < <(collect_files "${dir}" "${WITH_STORE}")
  [[ ${#files[@]} -gt 0 ]] || die "${dir} 下没有任何可备份的身份/配置文件"

  tar -czf "${out}" -C "${dir}" "${files[@]}"
  chmod 600 "${out}" 2>/dev/null || true

  echo "已备份 → ${out}"
  echo "  源目录：$(abspath "${dir}")"
  echo "  内容："
  printf '    %s\n' "${files[@]}"
  if [[ ! -e "${dir}/state/gateway-ca.key.pem" && ! -e "${dir}/state/dev-ca.key.pem" ]]; then
    echo "  注意：未找到网关 CA 私钥 —— 若这台还没建 CA，备份不含信任锚。" >&2
  fi
  if [[ "${WITH_STORE}" != "1" ]]; then
    echo
    echo "  未含：SQLite 库（agent 注册会由 mTLS 自动重建）／安装包缓存／指标历史／页面证书。"
    echo "        要保留管理面状态（派活、安装包录入记录等）加 --with-store。"
  fi
  echo
  echo "  输出含私钥，请保管到**安全且离机**的位置。"
}

do_check() {
  local dir="$1"
  [[ -d "${dir}" ]] || die "找不到源目录：${dir}"
  echo "会被备份的件（源目录 $(abspath "${dir}")）："
  local f any=0
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    printf '  %s\n' "${f}"
    any=1
  done < <(collect_files "${dir}" "${WITH_STORE}")
  [[ "${any}" == "1" ]] || echo "  （无）"
}

# ── 解析参数 ──
# 子命令可省：首参不是 backup/check/restore（而是 flag 或位置参数）时就当 backup。
case "${1:-}" in
  backup | check | restore)
    CMD="$1"
    shift
    ;;
esac
FROM=""
TO=""
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-store)
      WITH_STORE=1
      shift
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
    [[ -n "${OUT}" ]] || OUT="./wist-gateway-identity-$(date +%Y%m%d-%H%M%S).tar.gz"
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
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    die "未知子命令：${CMD}（可用：backup | check）"
    ;;
esac
