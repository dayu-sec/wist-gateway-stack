#!/usr/bin/env bash
# 备份 / 恢复网关的**身份与配置**（不可再生的 PEM）。默认**不含数据库与历史数据**。
#
# 口径（与 mTLS 身份模型一致）：
#   - **要备份**的是 PEM：网关 CA（信任锚 —— 丢了 = 全队 agent 重装）、叶证书、安装脚本签名密钥、
#     agent CA（若开了 mTLS 签发）；外加 `wist-gateway.value.json` 与渲染出的 `wist-gateway.toml`。
#   - **不用备份**数据库与历史数据：SQLite 里的 agent 注册会在 agent 重连时由 mTLS **自动重建**；
#     指标历史随时间贬值。只有想保留**管理面状态**（派活 / 安装包录入记录 / 用途与上送绑定等）才加 `--with-store`。
#   - 页面证书（`configs/web/tls/`）可重新生成（浏览器重新信任即可）；安装包缓存可重新录入 —— 都不备份。
#
# 用法：
#   scripts/backup-gateway.sh                             # 备份 configs/gateway → ./wist-gateway-identity-<ts>.tar.gz
#   scripts/backup-gateway.sh --with-store                # 连同 SQLite 库一起（含管理面状态）
#   scripts/backup-gateway.sh backup  [config_dir] [out]  # 指定目标目录 / 输出文件
#   scripts/backup-gateway.sh restore <file> [config_dir] [--force]
#   scripts/backup-gateway.sh check   [config_dir]        # 只列会被备份的关键件，不写文件
#
# 开发态也可用：scripts/backup-gateway.sh backup ~/.wist-gateway
#
# 恢复：把 PEM 放回 `<config_dir>/state/` 即可（restore 会解包）。重启网关后，持有效客户端证书的
#       agent 会**自动重新登记**；被删掉的数据库/历史不会恢复，也不需要。
#
# 输出含私钥：请落到**安全且离机**的位置（脚本把产物权限设为 0600）。
set -euo pipefail

CMD="backup"
CONFIG_DIR="configs/gateway"
OUT=""
FILE=""
WITH_STORE=0
FORCE=0

die() {
  echo "错误：$*" >&2
  exit 1
}

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^#[[:space:]]\{0,1\}//'
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
  [[ -d "${dir}" ]] || die "找不到配置目录：${dir}（先跑 init-gateway / 起一次网关生成）"
  local files=() f
  while IFS= read -r f; do [[ -n "${f}" ]] && files+=("${f}"); done < <(collect_files "${dir}" "${WITH_STORE}")
  [[ ${#files[@]} -gt 0 ]] || die "${dir} 下没有任何可备份的身份/配置文件"

  tar -czf "${out}" -C "${dir}" "${files[@]}"
  chmod 600 "${out}" 2>/dev/null || true

  echo "已备份 → ${out}"
  echo "  来源：${dir}"
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

do_restore() {
  local file="$1" dir="$2"
  [[ -f "${file}" ]] || die "找不到备份文件：${file}"
  mkdir -p "${dir}/state"
  if [[ "${FORCE}" != "1" ]]; then
    local entry
    while IFS= read -r entry; do
      [[ "${entry}" == */ ]] && continue
      [[ -e "${dir}/${entry}" ]] && die "目标已存在：${dir}/${entry}（要覆盖加 --force）"
    done < <(tar -tzf "${file}")
  fi
  tar -xzf "${file}" -C "${dir}"
  echo "已恢复 → ${dir}"
  echo "  agent 身份：持有效客户端证书的 agent 会在重连时**自动重新登记**（无需人工）。"
  echo "  下一步：重启网关让新配置/证书生效 ——"
  echo "    ./dev/svc.sh stop gateway && ./dev/svc.sh start gateway        # 开发态"
  echo "    或 docker compose --project-directory . -f sys/docker-compose.yml restart gateway  # 发布态"
}

do_check() {
  local dir="$1"
  [[ -d "${dir}" ]] || die "找不到配置目录：${dir}"
  echo "会被备份的件（来源 ${dir}）："
  local f any=0
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    printf '  %s\n' "${f}"
    any=1
  done < <(collect_files "${dir}" "${WITH_STORE}")
  [[ "${any}" == "1" ]] || echo "  （无）"
}

# ── 解析参数 ──
args=("$@")
[[ ${#args[@]} -gt 0 ]] && { CMD="${args[0]}"; args=("${args[@]:1}"); }
positional=()
for a in "${args[@]:-}"; do
  case "${a}" in
    --with-store) WITH_STORE=1 ;;
    --force) FORCE=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "未知参数：${a}" ;;
    *) positional+=("${a}") ;;
  esac
done

case "${CMD}" in
  backup)
    [[ ${#positional[@]} -ge 1 ]] && CONFIG_DIR="${positional[0]}"
    [[ ${#positional[@]} -ge 2 ]] && OUT="${positional[1]}"
    [[ -n "${OUT}" ]] || OUT="./wist-gateway-identity-$(date +%Y%m%d-%H%M%S).tar.gz"
    do_backup "${CONFIG_DIR}" "${OUT}"
    ;;
  restore)
    [[ ${#positional[@]} -ge 1 ]] || die "用法：$0 restore <备份文件> [config_dir] [--force]"
    FILE="${positional[0]}"
    [[ ${#positional[@]} -ge 2 ]] && CONFIG_DIR="${positional[1]}"
    do_restore "${FILE}" "${CONFIG_DIR}"
    ;;
  check)
    [[ ${#positional[@]} -ge 1 ]] && CONFIG_DIR="${positional[0]}"
    do_check "${CONFIG_DIR}"
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    die "未知子命令：${CMD}（可用：backup | restore | check）"
    ;;
esac
