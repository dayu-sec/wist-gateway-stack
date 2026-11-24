#!/usr/bin/env bash
# 回归测试：`scripts/check-data-plane.sh` 的**判定分支**（不依赖真 docker / 真镜像）。
#
# 这个脚本本身不含规则（规则在引擎的 `wparse check`，见 wp-labs/warp-parse#375），
# 它唯一的价值是「在 pull/up 之前，用新镜像把两棵树判一遍，失败就阻断 localize」。
# 所以这里钉的是那几条分支：
#   1. 老镜像没有 `check` → **跳过**（不阻塞升级；升 WPARSE_TAG 后自动生效），且不跑实际检查；
#   2. 检查失败 → exit 1（localize ⑦ 失败 → `gops prj upgrade` 回滚）；
#   3. 检查通过 → exit 0，并且**种子与工作根各跑一次**、都是只读挂载；
#   4. docker 不可用（没装 / daemon 没起）→ 跳过（本地开发不该被拦），但要打出来；
#   5. 镜像不在本地 → 先 pull；pull 也失败 → exit 1（部署时同样缺这个镜像）。
#   6. 退出码分开报：`1` = 语义问题（重复 matcher）、`2` = 配置加载失败（变量 / endpoint）；
#      并把 **compose 注入的两个端点**显式传给检查容器（它们不在 `.env` 里，少了就会误红）。
#
#   dev/tests/data-plane-check.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
SCRIPT="${STACK_ROOT}/scripts/check-data-plane.sh"
[[ -x "${SCRIPT}" ]] || [[ -f "${SCRIPT}" ]] || { echo "找不到 ${SCRIPT}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

fail=0
bad() { echo "  [FAIL] $*" >&2; fail=1; }
ok() { echo "  [OK]   $*"; }

# 假 docker：把调用记进 $FAKE_LOG，按 FAKE_* 变量回答。判据脚本只用到 info / image / pull / run。
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/docker" <<'SHIM'
#!/bin/sh
echo "$*" >>"${FAKE_LOG}"
case "$*" in
  info) exit "${FAKE_INFO_RC:-0}" ;;
  "image inspect"*) exit "${FAKE_INSPECT_RC:-0}" ;;
  pull*) exit "${FAKE_PULL_RC:-0}" ;;
  *"check --help"*) exit "${FAKE_HELP_RC:-0}" ;;
  *"check --work-root"*) exit "${FAKE_CHECK_RC:-0}" ;;
  *) exit 0 ;;
esac
SHIM
chmod +x "${TMP}/bin/docker"

seed="${TMP}/seed"
work="${TMP}/work"
mkdir -p "${seed}" "${work}"

# run_case <名字> <期望退出码> <FAKE_* 环境...>：在隔离的 FAKE_LOG 上跑一次
run_case() {
  local name="$1" want="$2"
  shift 2
  export FAKE_LOG="${TMP}/${name}.log"
  : >"${FAKE_LOG}"
  set +e
  # shellcheck disable=SC2086  # 由调用方给出的 KEY=VAL 列表
  PATH="${TMP}/bin:${PATH}" "$@" "${SCRIPT}" \
    --image "example.test/warp-parse:fake" --seed "${seed}" --work "${work}" \
    >"${TMP}/${name}.out" 2>&1
  rc=$?
  set -e
  if [[ "${rc}" -eq "${want}" ]]; then
    ok "${name}（exit ${rc}）"
  else
    bad "${name}：期望 exit ${want}，实际 ${rc}；输出：$(cat "${TMP}/${name}.out")"
  fi
}

echo "== 1) 老镜像没有 check 子命令 → 跳过，不跑实际检查 =="
run_case old-image 0 env FAKE_HELP_RC=1
grep -q 'check --help' "${TMP}/old-image.log" || bad "没有探测 check 子命令"
grep -q 'check --work-root' "${TMP}/old-image.log" && bad "探测失败时仍跑了实际检查"
grep -q 'skip:' "${TMP}/old-image.out" || bad "跳过没有被说出来"

echo "== 2) 检查失败（exit 1，语义）→ exit 1，点名处置 =="
run_case check-fail 1 env FAKE_HELP_RC=0 FAKE_CHECK_RC=1
grep -q 'check --work-root' "${TMP}/check-fail.log" || bad "没有跑实际检查"
grep -q '种子与工作根都要改' "${TMP}/check-fail.out" || bad "失败时没有给出处置"
grep -q '语义问题' "${TMP}/check-fail.out" || bad "退出码 1 没有报成语义问题"

echo "== 2b) 配置加载失败（exit 2）→ 不能误报成重复绑定 =="
run_case check-load-fail 1 env FAKE_HELP_RC=0 FAKE_CHECK_RC=2
grep -q '配置加载失败' "${TMP}/check-load-fail.out" || bad "退出码 2 没报成配置加载失败"
grep -q '两个 sink 分组绑定' "${TMP}/check-load-fail.out" && bad "退出码 2 被误报成重复绑定"

echo "== 3) 检查通过 → exit 0，且两棵树各跑一次、都是只读挂载 =="
run_case check-ok 0 env FAKE_HELP_RC=0 FAKE_CHECK_RC=0
for want in "/check" "/work" ":ro"; do
  grep -q -- "${want}" "${TMP}/check-ok.log" || bad "调用里缺 ${want}（日志：$(cat "${TMP}/check-ok.log")）"
done
# 这两个端点只由 compose 注入（不在 .env）：不显式传，引擎会因 http.endpoint 不是 http(s) 直接失败。
for want in "WPARSE_VM_ENDPOINT=" "WPARSE_GATEWAY_ENDPOINT="; do
  grep -q -- "${want}" "${TMP}/check-ok.log" || bad "没把 ${want} 传给检查容器（日志：$(cat "${TMP}/check-ok.log")）"
done
n="$(grep -c 'check --work-root' "${TMP}/check-ok.log" || true)"
[[ "${n}" -eq 2 ]] || bad "期望种子 + 工作根各一次，实际 ${n} 次"

echo "== 4) docker 不可用（daemon 没起）→ 跳过 =="
run_case no-daemon 0 env FAKE_INFO_RC=1
grep -q 'skip:' "${TMP}/no-daemon.out" || bad "跳过没有被说出来"
grep -q 'check --work-root' "${TMP}/no-daemon.log" && bad "daemon 不可用时仍尝试跑检查"

echo "== 5) 镜像不在本地且拉取失败 → exit 1 =="
run_case pull-fail 1 env FAKE_INSPECT_RC=1 FAKE_PULL_RC=1
grep -q 'pull' "${TMP}/pull-fail.log" || bad "没有尝试拉取"
grep -q '拉不下来' "${TMP}/pull-fail.out" || bad "失败文案没说清缺镜像"

echo "== 6) 镜像不在本地但能拉取 → 继续检查 =="
run_case pull-ok 0 env FAKE_INSPECT_RC=1 FAKE_PULL_RC=0 FAKE_HELP_RC=0 FAKE_CHECK_RC=0

echo
if [[ "${fail}" == "0" ]]; then
  echo "data-plane check test passed"
else
  echo "data-plane check test FAILED" >&2
  echo "  说明：判据在引擎（warp-parse#375）；本脚本只负责「用新镜像、在 pull/up 之前、失败即阻断」。" >&2
  exit 1
fi
