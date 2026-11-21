#!/usr/bin/env bash
# 一键卸载本机 wist-gwlinkd（开发态 / 单机），可选**卸完就装回并重新接入**。
#
# 顺序（每一步都幂等）：
#   ① 备份 identity/ 与 gwlinkd 配置到 backups/（含客户端私钥 → 归档 0600）
#   ② 停服务 + `wist-gwlinkd unlink`：删**注册态**（客户端证书 / 链接配置 / regist-token /
#      身份 / 实例 / 业务身份 / 升级簿记 + 现场态 .env 里的接入券）—— 复用 dev/unlink-center.sh
#   ③ `service uninstall --system`：停用并删服务定义（plist / unit）
#   ④ 可选 --purge：删二进制（先备份到 backups/）
#   ⑤ 可选 --purge-config：删渲染出的 configs/gwlinkd（含 state_dir，归档已在 ①）
#   ⑥ 可选 --reset-center：把中心侧该实例打回 Provisioned（**仅本地开发库**）
#   ⑦ 可选 --rotate-token：向中心管理面要一张新的一次性接入券，写回现场态 .env
#   ⑧ 可选 --reinstall：立刻 `dev/install-gwlinkd-dev.sh --release` 装回并启动（随后自检）
#
# ⚠️ 为什么默认**不够**修「客户端证书已过期」：
#   卸载只清本机；中心仍认为该 gateway_id 已初始化（credential_token_hash 非空）时，
#   重装后 link-upstream 会被 401 certificate_required 拒绝（本仓有意不提供「重置实例」）。
#   要真正恢复，加 `--reset-center`（保号，仅本地库）或到中心换**新 gateway_id**。
#
# 用法：
#   ./dev/uninstall-gwlinkd.sh                 # 交互确认；只卸载（保二进制 / 配置 / 中心实例）
#   ./dev/uninstall-gwlinkd.sh --dry-run       # 只打印将执行的命令，不落盘、不动进程
#   ./dev/uninstall-gwlinkd.sh -y              # 不交互（脚本化）
#   ./dev/uninstall-gwlinkd.sh -y --purge      # 连二进制一起删（有备份）
#
#   # 典型「重装并重新接入」（证书过期 / 换了中心）：
#   ./dev/uninstall-gwlinkd.sh -y --reset-center --rotate-token --reinstall
#
# 可覆盖 env（--reset-center / --rotate-token 用）：
#   CENTER_PG_CONTAINER  (默认 wist-center-stack-postgres)
#   CENTER_PG_USER       (默认 demo)     CENTER_PG_DB (默认 insight_demo)
#   CENTER_PG_PASSWORD   (默认 demo)
#   CENTER_ADMIN_ADDR    (默认 https://127.0.0.1:3102)
#   CENTER_SEC_FILE      (默认 <同级的 wist-dev-center>/wist-center-stack/.wist/sec-value.yml)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IDENTITY_DIR="${STACK_ROOT}/identity/gwlinkd"
GW_CONFIG_DIR="${STACK_ROOT}/configs/gwlinkd"
PUB_ENV="${IDENTITY_DIR}/.env"
BACKUP_DIR="${STACK_ROOT}/backups"

SERVICE_NAME="wist-gwlinkd"
SERVICE_BIN="/usr/local/bin/${SERVICE_NAME}"
REAL_BIN="/usr/local/lib/${SERVICE_NAME}/${SERVICE_NAME}"
LAUNCHD_PLIST="/Library/LaunchDaemons/com.dayu-sec.wist-gwlinkd.plist"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"

CENTER_PG_CONTAINER="${CENTER_PG_CONTAINER:-wist-center-stack-postgres}"
CENTER_PG_USER="${CENTER_PG_USER:-demo}"
CENTER_PG_DB="${CENTER_PG_DB:-insight_demo}"
CENTER_PG_PASSWORD="${CENTER_PG_PASSWORD:-demo}"
CENTER_ADMIN_ADDR="${CENTER_ADMIN_ADDR:-https://127.0.0.1:3102}"
CENTER_SEC_FILE="${CENTER_SEC_FILE:-${STACK_ROOT}/../../wist-dev-center/wist-center-stack/.wist/sec-value.yml}"

DRY_RUN=0
ASSUME_YES=0
PURGE=0
PURGE_CONFIG=0
RESET_CENTER=0
ROTATE_TOKEN=0
REINSTALL=0
TOKEN=""

note() { printf '  %s\n' "$*"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[1;31m错误：%s\033[0m\n' "$*" >&2
  exit 1
}
# 需要 root 的动作：dry-run 只打印。
as_root() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '    [dry-run] sudo %s\n' "$*"
  else
    sudo "$@"
  fi
}
# 普通动作：dry-run 只打印。
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

usage() {
  cat >&2 <<'EOF'
用法：./dev/uninstall-gwlinkd.sh [选项]

  --dry-run            只打印将执行的命令（不落盘、不停进程）
  -y, --yes            不交互确认
  --purge              连二进制一起删（先备份到 backups/）
  --purge-config       删渲染出的 configs/gwlinkd（含 state_dir；归档已在备份里）
  --reset-center       把中心该实例打回 Provisioned（仅本地开发库）
  --rotate-token       向中心管理面轮换一次性接入券，并写回 identity/gwlinkd/.env
  --token <券>         直接指定接入券（与 --rotate-token 二选一）
  --reinstall          卸载后立刻用 dev/install-gwlinkd-dev.sh --release 装回并启动
  -h, --help           显示本帮助
EOF
}

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    --purge) PURGE=1 ;;
    --purge-config) PURGE_CONFIG=1 ;;
    --reset-center) RESET_CENTER=1 ;;
    --rotate-token) ROTATE_TOKEN=1 ;;
    --token)
      [[ $# -ge 2 ]] || die "--token 需要一个参数"
      TOKEN="$2"
      shift
      ;;
    --token=*) TOKEN="${1#*=}" ;;
    --reinstall) REINSTALL=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "未知参数：$1"
      ;;
  esac
  shift
done

[[ "${ROTATE_TOKEN}" == "1" && -n "${TOKEN}" ]] && die "--rotate-token 与 --token 只能选一个"
if [[ "${PURGE_CONFIG}" == "1" && "${REINSTALL}" == "1" ]]; then
  die "--purge-config 与 --reinstall 不能同次：配置被删后得先重渲（cd <工程根> && gops sys localize），再 --reinstall"
fi
if [[ "${ROTATE_TOKEN}" == "1" ]] && ! command -v python3 >/dev/null 2>&1; then
  die "缺少 python3（解析轮换券的响应）"
fi

# ── 现场态：gateway_id（用于中心侧操作） ──
GATEWAY_ID=""
if [[ -f "${PUB_ENV}" ]]; then
  GATEWAY_ID="$(awk -F'=' '/^GWLINKD_GATEWAY_ID=/{print $2}' "${PUB_ENV}" | tr -d '"[:space:]')"
fi
[[ -n "${GATEWAY_ID}" ]] || GATEWAY_ID="$(basename "$(dirname "${IDENTITY_DIR}")")"

extras=()
[[ ${PURGE} == 1 ]] && extras+=("--purge 删二进制")
[[ ${PURGE_CONFIG} == 1 ]] && extras+=("--purge-config 删配置")
[[ ${RESET_CENTER} == 1 ]] && extras+=("--reset-center")
[[ ${ROTATE_TOKEN} == 1 ]] && extras+=("--rotate-token")
[[ -n ${TOKEN} ]] && extras+=("--token")
[[ ${REINSTALL} == 1 ]] && extras+=("--reinstall")

printf '\033[1m本机 wist-gwlinkd 卸载\033[0m\n'
note "栈根      ${STACK_ROOT}"
note "身份目录  ${IDENTITY_DIR}"
note "服务      ${SERVICE_BIN}"
note "gateway_id ${GATEWAY_ID:-<未配置>}"
note "模式      $([[ ${DRY_RUN} == 1 ]] && echo 'dry-run（不落盘）' || echo '执行')"
note "额外动作  ${extras[*]:-无}"

if [[ "${ASSUME_YES}" != "1" && "${DRY_RUN}" != "1" ]]; then
  printf '\n这会删除本机注册态（客户端证书等，先备份）。确认继续？输入 yes：'
  reply=""
  read -r reply || true
  [[ "${reply}" == "yes" ]] || die "已取消"
fi

# ── ① 备份 ──
step "① 备份 identity/ 与 gwlinkd 配置"
TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DIR}/uninstall-gwlinkd-${TS}.tar.gz"
targets=()
[[ -d "${IDENTITY_DIR}" ]] && targets+=("identity/gwlinkd")
[[ -d "${GW_CONFIG_DIR}" ]] && targets+=("configs/gwlinkd")
if ((${#targets[@]} == 0)); then
  note "没有可备份的目录（可能已卸载过）"
elif [[ "${DRY_RUN}" == "1" ]]; then
  note "[dry-run] tar -czf ${ARCHIVE} -C ${STACK_ROOT} ${targets[*]}"
else
  mkdir -p "${BACKUP_DIR}"
  # state/ 由服务（root）写入 —— 普通用户可能读不到；读不到就降级用 sudo，再把归档还给人。
  if ! tar -czf "${ARCHIVE}" -C "${STACK_ROOT}" "${targets[@]}" 2>/dev/null; then
    note "普通用户读不全（state/ 属 root）→ 用 sudo 备份"
    as_root tar -czf "${ARCHIVE}" -C "${STACK_ROOT}" "${targets[@]}"
    as_root chown "$(id -u):$(id -g)" "${ARCHIVE}"
  fi
  chmod 600 "${ARCHIVE}" # 含客户端私钥
  note "已备份：${ARCHIVE}"
fi

# ── ② 停服务 + unlink（注册态的唯一 owner 是 gwlinkd 自己） ──
step "② 停服务 + 清除注册态（unlink）"
[[ -x "${SCRIPT_DIR}/unlink-center.sh" ]] || die "缺少 ${SCRIPT_DIR}/unlink-center.sh"
unlink_args=(--no-restart)
[[ "${DRY_RUN}" == "1" ]] && unlink_args=(--dry-run --no-restart)
"${SCRIPT_DIR}/unlink-center.sh" "${unlink_args[@]}"

# ── ③ 删服务定义 ──
step "③ 删除服务定义（service uninstall）"
if [[ -f "${LAUNCHD_PLIST}" || -f "${SYSTEMD_UNIT}" ]]; then
  if [[ -x "${SERVICE_BIN}" ]]; then
    as_root "${SERVICE_BIN}" service uninstall --system
  else
    # 二进制已被删（上次 --purge）→ 直接清定义文件，别让卸载卡在这里。
    [[ -f "${LAUNCHD_PLIST}" ]] && as_root rm -f "${LAUNCHD_PLIST}"
    [[ -f "${SYSTEMD_UNIT}" ]] && as_root rm -f "${SYSTEMD_UNIT}"
  fi
else
  note "没有已安装的服务定义（跳过）"
fi

# ── ④ 可选：删二进制 ──
if [[ "${PURGE}" == "1" ]]; then
  step "④ 删除二进制（先备份）"
  if [[ -f "${REAL_BIN}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      note "[dry-run] cp -p ${REAL_BIN} ${BACKUP_DIR}/wist-gwlinkd-${TS}"
    else
      mkdir -p "${BACKUP_DIR}"
      cp -p "${REAL_BIN}" "${BACKUP_DIR}/wist-gwlinkd-${TS}" 2>/dev/null ||
        as_root cp -p "${REAL_BIN}" "${BACKUP_DIR}/wist-gwlinkd-${TS}"
      note "已备份二进制：${BACKUP_DIR}/wist-gwlinkd-${TS}"
    fi
    as_root rm -f "${SERVICE_BIN}" "${REAL_BIN}"
  else
    note "二进制不在 ${REAL_BIN}（跳过）"
  fi
fi

# ── ⑤ 可选：删配置（含 state_dir） ──
if [[ "${PURGE_CONFIG}" == "1" ]]; then
  step "⑤ 删除渲染出的 gwlinkd 配置（configs/gwlinkd）"
  if [[ -d "${GW_CONFIG_DIR}" ]]; then
    as_root rm -rf "${GW_CONFIG_DIR}"
    note "已删除 ${GW_CONFIG_DIR}（归档见上；重装时 gops sys localize 会重渲）"
  else
    note "配置目录不存在（跳过）"
  fi
fi

# ── ⑥ 可选：中心打回 Provisioned（仅本地开发库） ──
if [[ "${RESET_CENTER}" == "1" ]]; then
  step "⑥ 中心侧把 ${GATEWAY_ID} 打回 Provisioned（仅本地开发库）"
  [[ -n "${GATEWAY_ID}" ]] || die "读不出 gateway_id，无法重置中心实例"
  command -v docker >/dev/null 2>&1 || die "缺少 docker"
  sql="UPDATE gateways SET credential_token_hash='', credential_status='active',
              credential_expires_at=NULL, lifecycle_state='Provisioned',
              initialized_at=NULL, instance_id=''
        WHERE gateway_id='${GATEWAY_ID}';"
  if [[ "${DRY_RUN}" == "1" ]]; then
    note "[dry-run] docker exec -e PGPASSWORD=*** ${CENTER_PG_CONTAINER} psql -U ${CENTER_PG_USER} -d ${CENTER_PG_DB} -c \"${sql//$'\n'/ }\""
  else
    out="$(docker exec -e "PGPASSWORD=${CENTER_PG_PASSWORD}" "${CENTER_PG_CONTAINER}" \
      psql -U "${CENTER_PG_USER}" -d "${CENTER_PG_DB}" -v ON_ERROR_STOP=1 -c "${sql}" 2>&1)" ||
      die "中心库更新失败：${out}"
    printf '%s\n' "${out}" | tail -3
    docker exec -e "PGPASSWORD=${CENTER_PG_PASSWORD}" "${CENTER_PG_CONTAINER}" \
      psql -U "${CENTER_PG_USER}" -d "${CENTER_PG_DB}" -c \
      "select gateway_id, lifecycle_state, credential_expires_at from gateways where gateway_id='${GATEWAY_ID}';"
  fi
fi

# ── ⑦ 可选：轮换一次性接入券 ──
if [[ "${ROTATE_TOKEN}" == "1" ]]; then
  step "⑦ 向中心轮换一次性接入券"
  [[ -n "${GATEWAY_ID}" ]] || die "读不出 gateway_id，无法轮换接入券"
  [[ -f "${CENTER_SEC_FILE}" ]] || die "缺少中心密钥文件：${CENTER_SEC_FILE}（用 CENTER_SEC_FILE=... 指定）"
  admin="$(awk -F': *' '/^center_admin_token:/{print $2}' "${CENTER_SEC_FILE}" | tr -d '"[:space:]')"
  [[ -n "${admin}" ]] || die "从 ${CENTER_SEC_FILE} 读不到 center_admin_token"
  if [[ "${DRY_RUN}" == "1" ]]; then
    note "[dry-run] POST ${CENTER_ADMIN_ADDR}/api/v1/admin/gateways/${GATEWAY_ID}/link-token"
  else
    resp="$(curl -skS -X POST "${CENTER_ADMIN_ADDR}/api/v1/admin/gateways/${GATEWAY_ID}/link-token" \
      -H "Authorization: Bearer ${admin}" -H 'content-type: application/json' \
      -d '{"requested_by":"uninstall-gwlinkd.sh"}')" || die "轮换接入券请求失败"
    TOKEN="$(printf '%s' "${resp}" | python3 -c \
      'import json,sys; print(json.load(sys.stdin)["install"]["link_token"])' 2>/dev/null)" ||
      die "解析轮换响应失败：${resp}"
    [[ -n "${TOKEN}" ]] || die "轮换响应里没有 link_token：${resp}"
    note "已拿到新接入券（${#TOKEN} 字符，15 分钟内有效）"
  fi
fi

# ── ⑧ 写券 ──
if [[ -n "${TOKEN}" || "${ROTATE_TOKEN}" == "1" ]]; then
  step "⑧ 把接入券写入现场态（${PUB_ENV}）"
  if [[ "${DRY_RUN}" == "1" ]]; then
    note "[dry-run] 追加 GWLINKD_LINK_TOKEN=***"
  else
    [[ -d "${IDENTITY_DIR}" ]] || mkdir -p "${IDENTITY_DIR}"
    if [[ -f "${PUB_ENV}" ]] && awk '/^GWLINKD_LINK_TOKEN=/{found=1} END{exit !found}' "${PUB_ENV}"; then
      # 已有该键（unlink 通常已删）→ 就地替换
      tmp="$(mktemp)"
      awk '/^GWLINKD_LINK_TOKEN=/{next} {print}' "${PUB_ENV}" >"${tmp}"
      mv "${tmp}" "${PUB_ENV}"
    fi
    printf '\nGWLINKD_LINK_TOKEN=%s\n' "${TOKEN}" >>"${PUB_ENV}"
    chmod 600 "${PUB_ENV}" 2>/dev/null || true
    note "已写入（一次性；接入成功后 gwlinkd 会自己删掉这一行）"
  fi
fi

# ── ⑨ 可选：装回并启动 ──
if [[ "${REINSTALL}" == "1" ]]; then
  step "⑨ 装回并启动（dev/install-gwlinkd-dev.sh --release）"
  [[ -x "${SCRIPT_DIR}/install-gwlinkd-dev.sh" ]] || die "缺少 ${SCRIPT_DIR}/install-gwlinkd-dev.sh"
  if [[ "${DRY_RUN}" == "1" ]]; then
    note "[dry-run] ${SCRIPT_DIR}/install-gwlinkd-dev.sh --release"
  else
    "${SCRIPT_DIR}/install-gwlinkd-dev.sh" --release
  fi
fi

# ── 收尾：提示下一步 ──
step "完成"
if [[ "${REINSTALL}" != "1" ]]; then
  note "装回：  ./dev/install-gwlinkd-dev.sh --release"
  if [[ -z "${TOKEN}" ]]; then
    note "拿券：  ./dev/uninstall-gwlinkd.sh -y --rotate-token --reinstall --reset-center"
    note "        （或中心「接入材料」页轮换券后，把 GWLINKD_LINK_TOKEN 写进 ${PUB_ENV}）"
  fi
fi
if [[ "${RESET_CENTER}" != "1" && -z "${TOKEN}" ]]; then
  warn "本机注册态已清，但中心仍认为 ${GATEWAY_ID} 已初始化 —— 直接重装会被 401 certificate_required。"
  warn "要恢复：加 --reset-center（本地 dev 库）或到中心换新 gateway_id 再接入。"
fi
if [[ "${DRY_RUN}" == "1" ]]; then
  note "dry-run：以上均未执行。"
fi
