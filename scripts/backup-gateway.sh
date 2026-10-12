#!/usr/bin/env bash
# 备份网关的**身份与运行状态**。备份分**两级**，用 `--level` 选；恢复见 `restore-gateway.sh`。
#
# 打点相对**栈根**（不是 `configs/gateway`）：站点身份（CA / 证书 / 私钥）已从资源树里拆出，放**栈根**
# `identity/gateway/{public,private}`（dev/prod 共用；配置里以 `identity/public|private/…` 相对引用），
# 资源（渲染配置 / store 库）仍在 `configs/gateway/`。
#
# 级别：
#   - `rebuild`（可重建级，**默认**）：把网关**重新立起来**所需的全部 —— 身份 PEM（网关 CA = 信任锚，
#     丢了 = 全队 agent 重装；agent CA；服务端叶证书；安装脚本签名密钥）＋ 渲染好的 `wist-gateway.toml`。
#     恢复后**直接起网关即可**，不必再跑 localize 渲染。
#   - `restore`（可还原级）：在可重建级之上，再带 `wist-gateway.value.json`（渲染源：域名 / 观测端点 /
#     知识库验签公钥）与 **SQLite 库** —— 按原样还原管理面状态（派活 / 安装包录入 / 用途与上送绑定等）。
#
# 两级都**不含**（都可重生成/重导入）：指标历史（VictoriaMetrics 卷，随时间贬值）、安装包缓存、
# 页面证书（`identity/web/`）、`configs/gateway/content/`。
# **也不含网关 admin token**：它不在 value.json 里，而在栈根 `.wist/sec-value.yml`（`wist-gateway.toml`
# 里写的 `${SEC_ADMIN_TOKEN}` 只是占位）。要连它一起还原，走 `gops prj backup` —— `sys-prj.yml`
# 的 backup 档已含 `.wist`。本脚本只管**身份 PEM + 渲染好的 toml + value.json + 库**。
#
# 用法：
#   scripts/backup-gateway.sh [--level rebuild|restore] [--from <栈根>] [--to <输出文件>]
#   scripts/backup-gateway.sh check [--level rebuild|restore] [--from <栈根>]
#   scripts/backup-gateway.sh list  [备份文件|目录]     # 列已备份的归档；给了归档文件则列其内容
#
# 参数：
#   --level <级别>   rebuild（可重建级，默认）| restore（可还原级）
#   --from <栈根>    备份的**源根**（默认 `.`，即栈根）—— 打包条目一律相对它，如
#                    `identity/gateway/private/gateway-ca.key.pem`、`configs/gateway/wist-gateway.toml`。
#                    开发态同样传**栈根**（`--from .`）：dev 的身份就是栈根这份共享身份；dev 的运行态
#                    （`dev/configs/gateway/state/` 下的 store 库）不在这套相对栈根的固定条目里。
#   --to <文件>      输出文件（默认 ./wist-gateway-backup-<时间戳>.tar.gz）
#
# 恢复用独立脚本：scripts/restore-gateway.sh <备份文件> [--to <栈根>] [--force] [--restart]
# 输出含私钥：请落到**安全且离机**的位置（脚本把产物权限设为 0600）。
set -euo pipefail

CMD="backup"
SRC_ROOT=""
OUT=""
LEVEL="rebuild"

DEFAULT_SRC_ROOT="."   # 源根 = 栈根（身份在 identity/、资源在 configs/gateway/；见头注释）
LEVELS="rebuild restore"

die() {
  echo "错误：$*" >&2
  exit 1
}

abspath() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$1")") || printf '%s\n' "$1"; }

usage() {
  # 打印文件头的**注释块**（第 2 行起，到首个非注释行为止）：加/删注释行都不用改行号。
  awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

level_label() {
  case "$1" in
    rebuild) echo "可重建级" ;;
    restore) echo "可还原级" ;;
    *) echo "$1" ;;
  esac
}

# 会进备份的相对路径（**相对栈根**；只收**存在**的）。
#   可重建级：身份 PEM（`identity/gateway/{public,private}`）+ **gwlinkd 的站点身份**
#               （`identity/gwlinkd/{pub.toml,control-center.pem,credential.json}`）
#               + 渲染好的 `configs/gateway/wist-gateway.toml`。
#   可还原级：再 + 渲染源 `value.json` + SQLite 库（`configs/gateway/state/`）。
#
# ⚠ gwlinkd 的 `credential.json`（客户端证书 + 私钥）**不可再生**：丢了只能到中心**新建实例、
#   换 `gateway_id`**（中心无“重置实例”接口）。它与 `pub.toml`（现场接线）一起属 `contract` 档，
#   落点与 `gops prj contract export` 一致。
collect_files() {
  local root="$1" rel f
  for rel in \
    identity/gateway/public/gateway-ca.crt.pem  identity/gateway/private/gateway-ca.key.pem \
    identity/gateway/public/agent-ca.crt.pem    identity/gateway/private/agent-ca.key.pem \
    identity/gateway/public/admin-tls.crt.pem   identity/gateway/private/admin-tls.key.pem \
    identity/gateway/private/install-script-signing-ed25519.pkcs8.pem \
    identity/gwlinkd/gwlinkd-pub.toml          identity/gwlinkd/control-center.pem \
    identity/gwlinkd/credential.json             identity/gwlinkd/.env \
    configs/gateway/wist-gateway.toml; do
    [[ -e "${root}/${rel}" ]] && printf '%s\n' "${rel}"
  done
  if [[ "${LEVEL}" == "restore" ]]; then
    for rel in configs/gateway/wist-gateway.value.json; do
      [[ -e "${root}/${rel}" ]] && printf '%s\n' "${rel}"
    done
    for f in "${root}"/configs/gateway/state/*.db "${root}"/configs/gateway/state/*.db-wal "${root}"/configs/gateway/state/*.db-shm; do
      [[ -e "${f}" ]] && printf '%s\n' "configs/gateway/state/$(basename "${f}")"
    done
  fi
}

do_backup() {
  local root="$1" out="$2"
  [[ -d "${root}" ]] || die "找不到源根（栈根）：${root}（先跑 init-gateway / 起一次网关生成身份，再在栈根执行；开发态也是栈根）"
  local files=() f
  while IFS= read -r f; do [[ -n "${f}" ]] && files+=("${f}"); done < <(collect_files "${root}")
  [[ ${#files[@]} -gt 0 ]] || die "${root} 下没有任何可备份的身份/配置文件"

  tar -czf "${out}" -C "${root}" "${files[@]}"
  chmod 600 "${out}" 2>/dev/null || true

  echo "已备份（$(level_label "${LEVEL}")）→ ${out}"
  echo "  源根：$(abspath "${root}")"
  echo "  内容："
  printf '    %s\n' "${files[@]}"
  if [[ ! -e "${root}/identity/gateway/private/gateway-ca.key.pem" ]]; then
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
  local root="$1"
  [[ -d "${root}" ]] || die "找不到源根（栈根）：${root}"
  echo "会被备份的件（$(level_label "${LEVEL}")；源根 $(abspath "${root}")）："
  local f any=0
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    printf '  %s\n' "${f}"
    any=1
  done < <(collect_files "${root}")
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
    echo "  （无。先跑：./scripts/backup-gateway.sh --from .）"
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
      [[ -n "${2:-}" ]] || die "--from 需要一个源根（栈根）"
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
    SRC_ROOT="${FROM:-${positional[0]:-${DEFAULT_SRC_ROOT}}}"
    OUT="${TO:-${positional[1]:-}}"
    [[ -n "${OUT}" ]] || OUT="./wist-gateway-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    do_backup "${SRC_ROOT}" "${OUT}"
    ;;
  restore)
    usage >&2
    die "恢复请用另一个脚本：scripts/restore-gateway.sh <备份文件> [--to <栈根>] [--force] [--restart]"
    ;;
  check)
    SRC_ROOT="${FROM:-${positional[0]:-${DEFAULT_SRC_ROOT}}}"
    do_check "${SRC_ROOT}"
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
