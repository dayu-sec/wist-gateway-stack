#!/usr/bin/env bash
# 嵌套挂载判据的单元测试（不需要 docker：喂的是 `docker compose config` 的**渲染结果**形状）。
#
# 钉住的行为（2026-11-14 事故的机制层回归）：
#   1. 父挂载 `:ro` + 子挂载点在宿主上不存在 → 报错，并点明「只读挂载建不出挂载点」；
#   2. 父挂载可写 + 子挂载点不存在 → 也报错，并点明「Docker 会以 root 建，随后 perms 整片失败」；
#   3. 子挂载点已存在且类型对 → 通过（wparse 的 /data/{data,.run,identity} 就是这么用的）；
#   4. 挂文件却落在目录上 → 报「类型不符」（Docker 会报 not a directory）；
#   5. `declared` 模式：宿主上不存在但被 `scripts/*.sh` 声明过 → 通过（干净 checkout 用）；
#   6. `declared` 模式：宿主上不存在且没声明过 → 仍然失败（「新加嵌套挂载却没人预建」）。
#
#   dev/tests/nested-mounts.test.sh
set -uo pipefail

S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${S}/scripts/lib/nested-mounts.sh"
[ -f "${LIB}" ] || {
  echo "找不到 ${LIB}" >&2
  exit 1
}
# shellcheck source=../../scripts/lib/nested-mounts.sh
. "${LIB}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

ROOT="${TMP}/root"
mkdir -p "${ROOT}/conf" "${ROOT}/scripts" "${ROOT}/data-plane-run/work"
printf 'x\n' >"${ROOT}/ca.pem"
# 声明过 `/work/data` 的「预建清单」（照 init-wparse-admin.sh 的写法）
printf 'mkdir -p "${RUN_DIR}/work/data"\n' >"${ROOT}/scripts/init-x.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }

nf() { # nf <rendered 文件> <模式> → 打印问题行
  nested_mount_problems "${ROOT}" "$2" "$1"
}

# 渲染结果的最小形状：与 `docker compose config` 一致
render() { # render <文件> <父source> <父target> <父read_only> <子source> <子target> [<子类型>]
  local out="$1" rw=""
  [ "$4" = "true" ] && rw="        read_only: true
"
  cat >"${out}" <<YAML
name: t
services:
  svc:
    image: x
    volumes:
      - type: bind
        source: $2
        target: $3
${rw}        bind: {}
      - type: ${7:-bind}
        source: $5
        target: $6
YAML
}

echo "① 父挂载 :ro + 挂载点缺失 → 硬失败"
render "${TMP}/a.yml" "${ROOT}/conf" /etc/x true "${ROOT}/ca.pem" /etc/x/ca.pem
out=$(nf "${TMP}/a.yml" strict)
case "${out}" in
  *":ro"*"建不出挂载点"*) ok "报出只读挂载建不出挂载点" ;;
  *) no "没报出只读挂载的原因：${out:-（空）}" ;;
esac

echo "② 父挂载可写 + 挂载点缺失 → 也要失败（Docker 会以 root 建）"
render "${TMP}/b.yml" "${ROOT}/conf" /etc/x false "${ROOT}/ca.pem" /etc/x/ca.pem
out=$(nf "${TMP}/b.yml" strict)
case "${out}" in
  *"以 root 建"*) ok "报出 root 预建 / perms 风险" ;;
  *) no "没报出可写父挂载的风险：${out:-（空）}" ;;
esac

echo "③ 挂载点已存在且类型对 → 通过"
printf 'pem\n' >"${ROOT}/conf/ca.pem"
render "${TMP}/c.yml" "${ROOT}/conf" /etc/x true "${ROOT}/ca.pem" /etc/x/ca.pem
out=$(nf "${TMP}/c.yml" strict)
if [ -z "${out}" ]; then ok "存在的挂载点不报错"; else no "误报：${out}"; fi

echo "④ 挂文件却落在目录上 → 类型不符"
rm -f "${ROOT}/conf/ca.pem"
mkdir -p "${ROOT}/conf/ca.pem"
render "${TMP}/d.yml" "${ROOT}/conf" /etc/x true "${ROOT}/ca.pem" /etc/x/ca.pem
out=$(nf "${TMP}/d.yml" strict)
case "${out}" in
  *"类型不符"*) ok "报出类型不符" ;;
  *) no "没报出类型不符：${out:-（空）}" ;;
esac
rmdir "${ROOT}/conf/ca.pem" 2>/dev/null || true

echo "⑤ declared 模式：宿主没有但在脚本里声明过 → 通过（干净 checkout）"
render "${TMP}/e.yml" "${ROOT}/data-plane-run" /data false "${ROOT}/elsewhere" /data/work/data
out=$(nf "${TMP}/e.yml" declared)
if [ -z "${out}" ]; then ok "被 init 脚本声明过的嵌套挂载不算失败"; else no "误报：${out}"; fi
out=$(nf "${TMP}/e.yml" strict)
case "${out}" in
  *"不存在"*) ok "strict 模式下同一路径仍然失败（localize 期必须真的存在）" ;;
  *) no "strict 模式没拦住：${out:-（空）}" ;;
esac

echo "⑥ declared 模式：宿主没有、也没任何脚本预建 → 仍然失败"
render "${TMP}/f.yml" "${ROOT}/conf" /etc/x true "${ROOT}/ca.pem" /etc/x/gateway-ca.pem
out=$(nf "${TMP}/f.yml" declared)
case "${out}" in
  *"/etc/x/gateway-ca.pem"*) ok "没人预建的新嵌套挂载被拦下" ;;
  *) no "漏放行：${out:-（空）}" ;;
esac

echo "⑦ 没有嵌套 → 通过"
render "${TMP}/g.yml" "${ROOT}/conf" /etc/x true "${ROOT}/ca.pem" /etc/ca.pem
out=$(nf "${TMP}/g.yml" strict)
if [ -z "${out}" ]; then ok "无嵌套不报错"; else no "误报：${out}"; fi

printf '\n通过 %d，失败 %d\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
