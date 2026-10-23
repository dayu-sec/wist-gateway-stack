#!/usr/bin/env bash
# 回归测试：`scripts/init-gwlinkd-pub.sh` 的现场态值自愈。
#
# 事故背景（2026-10-23，现场 wparse 容器 restarting 52 次）：
#   `identity/gwlinkd/control-center.pem` 缺失时，compose 里那条 bind 被 docker **建成目录**；
#   wparse 把它当 `SSL_CERT_FILE`，构造 HTTP 客户端失败（`build victoriametric client failed`），
#   容器无限重启。这个目录还会**挡住** CA 写回原位 —— 所以 localize 阶段要能自己清掉它。
#
# 钉住的行为：
#   1. 信任锚位置是**空目录**（docker 造的）→ 删掉它，脚本仍 exit 0；
#   2. 信任锚位置是**非空目录** → 不碰（可能是现场自己放的），也不报错；
#   3. 信任锚是**真文件** → 保留，重复跑不改 `.env`（幂等）；
#   4. 声明里没引用的键 → 清掉（死键），声明里引用的保留。
#
#   dev/tests/init-gwlinkd-pub.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
SCRIPT="${STACK_ROOT}/scripts/init-gwlinkd-pub.sh"
[[ -f "${SCRIPT}" ]] || { echo "找不到 ${SCRIPT}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# 脚本要 python3；最小 PATH 里通常就有（/usr/bin）。缺了就别在这台机器上判。
command -v python3 >/dev/null 2>&1 || { echo "SKIP：没有 python3" ; exit 0; }

fail() { echo "FAIL：$*" >&2; exit 1; }

mk_state() { # $1=目录
  local d="$1"
  mkdir -p "${d}"
  cat > "${d}/gwlinkd-pub.toml" <<'TOML'
center_endpoint = "${GWLINKD_CENTER_ENDPOINT}"
gateway_id = "${GWLINKD_GATEWAY_ID}"
trust_bundle = "${GWLINKD_TRUST_BUNDLE}"
TOML
  cat > "${d}/.env" <<'ENV'
GWLINKD_CENTER_ENDPOINT=https://center.example
GWLINKD_GATEWAY_ID=gw-1
GWLINKD_TRUST_BUNDLE=./control-center.pem
OLD_KEY=stale
ENV
}

run_init() { # $1=现场态目录
  ( cd "${STACK_ROOT}" && bash "${SCRIPT}" "$1" 2>&1 )
}

# 1) 空目录（docker 造出来的那种）→ 删掉
state="${TMP}/empty-dir"
mk_state "${state}"
mkdir -p "${state}/control-center.pem"
out="$(run_init "${state}")" || fail "信任锚是空目录时脚本不该失败：${out}"
[[ -d "${state}/control-center.pem" ]] && fail "空目录没被清掉：${out}"
grep -q "已删除 docker 建出的空目录" <<<"${out}" || fail "没有说明为什么删：${out}"

# 2) 非空目录 → 不动
state="${TMP}/nonempty-dir"
mk_state "${state}"
mkdir -p "${state}/control-center.pem"
: > "${state}/control-center.pem/keep"
run_init "${state}" >/dev/null || fail "非空目录不该让脚本失败"
[[ -d "${state}/control-center.pem" && -f "${state}/control-center.pem/keep" ]] \
  || fail "非空目录被删了"

# 3) 真 PEM → 保留，重复跑不改内容（幂等）
state="${TMP}/real-file"
mk_state "${state}"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' \
  > "${state}/control-center.pem"
# 第一次跑会把死键清掉（见 case 4）；从那之后才是稳定态。
run_init "${state}" >/dev/null || fail "信任锚是真文件时脚本不该失败"
[[ -f "${state}/control-center.pem" ]] || fail "真文件被删了"
before="$(if command -v shasum >/dev/null 2>&1; then shasum -a 256 "${state}/.env"; else sha256sum "${state}/.env"; fi)"
out="$(run_init "${state}")" || fail "重复跑不该失败：${out}"
after="$(if command -v shasum >/dev/null 2>&1; then shasum -a 256 "${state}/.env"; else sha256sum "${state}/.env"; fi)"
[[ "${before}" == "${after}" ]] || fail "重复跑改动了 .env（不幂等）"
grep -q "与当前一致" <<<"${out}" || fail "重复跑没有保持幂等：${out}"
[[ -f "${state}/control-center.pem" ]] || fail "重复跑后真文件不见了"

# 4) 死键清理：OLD_KEY 未被声明引用 → 删；声明的三项保留
state="${TMP}/dead-keys"
mk_state "${state}"
run_init "${state}" >/dev/null || fail "死键清理不该让脚本失败"
grep -q '^OLD_KEY=' "${state}/.env" && fail "死键 OLD_KEY 没被清掉"
for key in GWLINKD_CENTER_ENDPOINT GWLINKD_GATEWAY_ID GWLINKD_TRUST_BUNDLE; do
  grep -q "^${key}=" "${state}/.env" || fail "声明的键 ${key} 被误删"
done

# 5) 容器投影（结构契约，见脚本里的说明）：
#    真身有 CA → 投到 <state>/trust/control-center.pem（内容一致）
#    真身没 CA → 投影删掉（不留陈旧 CA）；容器目录本身必须存在
state="${TMP}/projection"
mk_state "${state}"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' \
  > "${state}/control-center.pem"
run_init "${state}" >/dev/null || fail "投影不该让脚本失败"
[[ -d "${state}/trust" ]] || fail "容器挂载目录 trust/ 没建出来"
cmp -s "${state}/control-center.pem" "${state}/trust/control-center.pem" \
  || fail "投影内容与真身不一致"
# 中心轮换 / 数据撤销：真身没了，投影必须跟着消失
rm -f "${state}/control-center.pem"
run_init "${state}" >/dev/null || fail "没有 CA 时不该失败（合法现场）"
[[ -d "${state}/trust" ]] || fail "没有 CA 时 trust/ 目录也必须存在（Compose 挂载源）"
[[ -e "${state}/trust/control-center.pem" ]] && fail "真身没了，投影还留着"

# 6) 投影位置被人弄成了非空目录 → 必须明确报错，不能默默写进去
state="${TMP}/projection-dir"
mk_state "${state}"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' \
  > "${state}/control-center.pem"
mkdir -p "${state}/trust/control-center.pem"
: > "${state}/trust/control-center.pem/keep"
if out="$(run_init "${state}")"; then
  fail "投影位置是非空目录时应该失败：${out}"
fi
grep -q "无法投影" <<<"${out}" || fail "没给出明确原因：${out}"

echo "OK：init-gwlinkd-pub 的现场态自愈与信任锚投影符合预期"
