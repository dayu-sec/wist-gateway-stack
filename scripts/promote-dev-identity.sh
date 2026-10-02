#!/usr/bin/env bash
# 把开发态网关的**身份（PEM）+ 管理面状态（SQLite 库）**搬成发布态网关的 —— 只做这一件事。
#
# 不碰容器：不 stop / start / restart 任何服务。搬完该不该重启网关，你自己决定（见结尾提示）。
#
# 为什么连库一起搬：库里存着 agent 的**凭据**；只搬 PEM、不搬库，老 agent 会 **401**。
# 为什么不动配置：`wist-gateway.toml` / `value.json` 保留发布态自己的（开发态那份路径不同）。
#
# 用法：
#   scripts/promote-dev-identity.sh [--from <源目录>] [--to <目标目录>] [--dry-run]
#
#   --from <目录>  来源（默认 ~/.wist-gateway，即开发态）
#   --to <目录>    发布态网关目录（默认 <栈根>/configs/gateway）；**必须已存在**
#   --dry-run      只打印要做的事，不写文件
#
# 等价于手工两步：
#   scripts/backup-gateway.sh --level restore --from <源> --to <临时包>
#   scripts/restore-gateway.sh <临时包> --to <目标> --no-config --force
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FROM="${HOME}/.wist-gateway"
TO="${STACK_ROOT}/configs/gateway"
DRY_RUN=0

die() {
  echo "错误：$*" >&2
  exit 1
}

abspath() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$1")") || printf '%s\n' "$1"; }

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^#[[:space:]]\{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      [[ -n "${2:-}" ]] || die "--from 需要一个目录"
      FROM="$2"
      shift 2
      ;;
    --to)
      [[ -n "${2:-}" ]] || die "--to 需要一个目录"
      TO="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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
      die "多余的位置参数：$1（请用 --from/--to）"
      ;;
  esac
done

# 护栏：源/目标都要对得上，且不能是同一个目录。
[[ -d "${FROM}" ]] || die "源目录不存在：${FROM}（开发态默认 ~/.wist-gateway）"
[[ -d "${TO}" ]] || die "目标目录不存在：${TO}
发布态网关目录应先初始化/起过一次。本脚本**不新建目录**，免得把东西写到错的位置。"
[[ -d "${TO}/state" || -f "${TO}/wist-gateway.toml" ]] || die "目标不像网关配置目录：${TO}（既无 state/ 也无 wist-gateway.toml）"
[[ "$(abspath "${FROM}")" != "$(abspath "${TO}")" ]] || die "源与目标是同一个目录（${TO}）—— 自搬自，没意义。"

fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'; }
subj() { openssl x509 -in "$1" -noout -subject 2>/dev/null; }

echo "源（来源）    ：$(abspath "${FROM}")"
echo "目标（发布态）：$(abspath "${TO}")"
[[ -f "${FROM}/state/gateway-ca.crt.pem" ]] &&
  printf '  源 CA  ：%s\n           [%s]\n' "$(subj "${FROM}/state/gateway-ca.crt.pem")" "$(fp "${FROM}/state/gateway-ca.crt.pem")"
[[ -f "${TO}/state/gateway-ca.crt.pem" ]] &&
  printf '  目标 CA：%s\n           [%s]\n' "$(subj "${TO}/state/gateway-ca.crt.pem")" "$(fp "${TO}/state/gateway-ca.crt.pem")"

if [[ "${DRY_RUN}" == "1" ]]; then
  echo
  echo "DRY_RUN：将会（① 出临时包；② 解到目标）"
  echo "  ${SCRIPT_DIR}/backup-gateway.sh --level restore --from ${FROM} --to <临时包>"
  echo "  ${SCRIPT_DIR}/restore-gateway.sh <临时包> --to ${TO} --no-config --force"
  exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
bundle="${tmpdir}/gateway.tar.gz"

echo
"${SCRIPT_DIR}/backup-gateway.sh" --level restore --from "${FROM}" --to "${bundle}"
echo
"${SCRIPT_DIR}/restore-gateway.sh" "${bundle}" --to "${TO}" --no-config --force

echo
echo "下一步（不在本脚本职责内）：若发布态网关在跑，重启它读新证书 ——"
echo "  docker compose --project-directory ${STACK_ROOT} -f ${STACK_ROOT}/sys/docker-compose.yml restart gateway"
echo "  另：搬进发布态目录的身份材料还要宿主属主/权限对齐（容器以 999:999 跑）。目标是 configs/gateway 时"
echo "      restore-gateway.sh 已自动跑过；其它目标请手动跑：${SCRIPT_DIR}/align-host-perms.sh ${STACK_ROOT}"
