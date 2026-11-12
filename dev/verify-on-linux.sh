#!/usr/bin/env bash
# 整栈升级预演：把上一版装起来，再升级到**当前工作树**，验证 localize 门禁/权限/容器能否一次过。
#
# 为什么需要它：`--config-only`、CI 的契约检查、真实机器上的 `perms --check` 都到不了
# localize 的 ⓿/⑥/⑦ 层。能覆盖"新包自己的门禁会不会把自己的升级拦下来"的，只有这里。
#
# 用法（**在 Linux 上跑**，需要 rootful docker + compose v2 + gops + gx）：
#   ./dev/verify-on-linux.sh --baseline v0.8.41-alpha          # 基线取 git tag
#   ./dev/verify-on-linux.sh --baseline ~/pkg/base.tar.gz      # 或用现成包
#   ./dev/verify-on-linux.sh --baseline v0.8.41-alpha --keep   # 保留现场便于事后看
#
# 选项：
#   --baseline <tag|tar.gz>  基线版本（缺省 v0.8.41-alpha）
#   --candidate <tar.gz>     候选包（缺省：从 --repo 的**工作树**现打）
#   --repo <dir>             仓库根（缺省 = 本脚本所在仓库）
#   --work <dir>             工作目录（缺省 ~/wv-rehearsal）
#   --domain <d>             站点域名（缺省 gw.rehearsal.test）
#   --bin-dir <dir>          预编译件目录（内含 bin/<triple>/wist-stackcheck）
#   --skip-start             基线只 localize 不启动（快，但少验 up/health）
#   --clean                  成功后删掉工作目录
#   --keep                   （缺省）保留工作目录与日志
#
# 前置（缺一条就白跑，脚本会先自检）：
#   · Linux 主机（可随意清空，**不要用生产机**）
#   · rootful docker + compose v2
#   · `gx`（galaxy-flow）—— localize 的流程引擎，缺了 regenerate 直接失败
#   · 部署账号已在容器 gid 组里（本栈 999；缺失时 ⓿ prereq 会正确拦截）
#   · 镜像源与知识库源可达
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SELF_DIR}/.." && pwd)"
BASELINE="v0.8.41-alpha"
CANDIDATE=""
WORK="${HOME}/wv-rehearsal"
DOMAIN="gw.rehearsal.test"
BIN_DIR=""
SKIP_START=0
CLEAN=0
PROJ_NAME="rehearsal"

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --baseline) BASELINE="${2:?--baseline 需要值}"; shift 2 ;;
    --candidate) CANDIDATE="${2:?--candidate 需要值}"; shift 2 ;;
    --repo) REPO="${2:?--repo 需要值}"; shift 2 ;;
    --work) WORK="${2:?--work 需要值}"; shift 2 ;;
    --domain) DOMAIN="${2:?--domain 需要值}"; shift 2 ;;
    --bin-dir) BIN_DIR="${2:?--bin-dir 需要值}"; shift 2 ;;
    --skip-start) SKIP_START=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --keep) shift ;;
    *) echo "未知选项：$1" >&2; exit 2 ;;
  esac
done

say() { printf '\n===== %s =====\n' "$*"; }
die() {
  printf '\n[FAIL] %s\n' "$*" >&2
  exit 1
}
ok() { printf '  [OK] %s\n' "$*"; }

TMPD="$(mktemp -d)"
STAGE=""
trap 'rm -rf "${TMPD}" ${STAGE:+"${STAGE}"}' EXIT

# `grep -q` 一旦匹配就退出，上游命令收到 SIGPIPE 被杀；在 `set -o pipefail` 下整条管道
# 返回非 0 —— 明明有匹配却判成没有。凡是「长输出 | grep -q」一律先落盘再匹配。
match_out() { # $1=ERE   stdin=待匹配内容
  cat >"${TMPD}/match"
  grep -qE "$1" "${TMPD}/match"
}

# 上个工程删不干净是本脚本常见的第二个坑：data-plane 由**容器身份**写入
# （属主 dnsmasq，属组 999），目录是 2755/2750 —— 组内没有 w 位，而删文件要求
# 对父目录可写，所以部署账号 rm 不掉。有免密 sudo 就自动用，没有就给出命令。
wipe_dir() {
  local d="$1"
  [ -e "$d" ] || return 0
  rm -rf "$d" 2>/dev/null
  [ -e "$d" ] || return 0
  if [ "$(id -u)" = 0 ]; then :; elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    sudo -n rm -rf "$d" 2>/dev/null
    [ -e "$d" ] || {
      echo "  [OK] 用 sudo 清理了旧工程 ${d}"
      return 0
    }
  fi
  die "删不掉 ${d}（data-plane 是容器身份写的只读目录）。手动清理：\n      sudo rm -rf ${d}"
}

# ── 0. 前置自检 ───────────────────────────────────────────────────────
say "0) 前置自检"
[ "$(uname -s)" = "Linux" ] || die "本脚本只能在 Linux 上跑（当前 $(uname -s)）"
command -v docker >/dev/null || die "缺少 docker"
docker info >/dev/null 2>&1 || die "docker daemon 不可用（rootless 下容器身份会映射到 subuid，预演失真；请用 rootful）"
docker compose version >/dev/null 2>&1 || die "缺少 compose v2 插件"
command -v gops >/dev/null || die "缺少 gops"
command -v gx >/dev/null || die "缺少 gx（galaxy-flow）：localize 的流程引擎，缺了 regenerate 必失败"
command -v python3 >/dev/null || die "缺少 python3"
command -v git >/dev/null || die "缺少 git（需要从仓库打基线/候选包）"
# rootless 下容器里的 999 会映射成宿主 subuid，宿主目录的所有权模型与生产不一致。
if docker info --format '{{.SecurityOptions}}' 2>/dev/null | match_out rootless; then
  die "检测到 rootless docker：容器身份会映射到 subuid，预演结果不代表生产（请用 rootful）"
fi
# 本栈的容器名是**固定字面量**（一宿主只允许一套）：已有同名容器时先停。
if docker ps --format '{{.Names}}' 2>/dev/null | match_out '^wist-gateway-stack-'; then
  echo "  占用中：$(docker ps --filter 'name=wist-gateway-stack-' --format '{{.Names}}' | tr '\n' ' ')" >&2
  die "本机已有 wist-gateway-stack-* 容器在跑（容器名是固定字面量，会互抢）。先停：\n      cd <上个工程的>/wist-gateway-stack && gops run stop\n      或 docker stop \$(docker ps -aq --filter name=wist-gateway-stack-)"
fi
ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') / compose $(docker compose version --short 2>/dev/null || echo '?')"
ok "gops $(gops --version 2>/dev/null | head -1 | awk '{print $2}') / gx $(gx --version 2>/dev/null | head -1 | awk '{print $2}')"

case "$(uname -m)" in
  aarch64 | arm64) HOST_TRIPLE=aarch64-unknown-linux-musl ;;
  x86_64 | amd64) HOST_TRIPLE=x86_64-unknown-linux-musl ;;
  *) HOST_TRIPLE="" ;;
esac

# ── 1. 打包（基线 + 候选）────────────────────────────────────────────
say "1) 打包"
mkdir -p "${WORK}/pkg"
STAGE="$(mktemp -d)"

stage_bins() { # 把可用的 stackcheck 预编译件聚到 $STAGE/bin/<triple>/
  local t src
  if [ -n "${BIN_DIR}" ]; then
    if [ -d "${BIN_DIR}/bin" ]; then
      cp -R "${BIN_DIR}/bin/." "${STAGE}/bin/"
    elif [ -d "${BIN_DIR}" ]; then
      mkdir -p "${STAGE}/bin/${HOST_TRIPLE:-unknown}"
      cp "${BIN_DIR}"/*"wist-stackcheck"* "${STAGE}/bin/${HOST_TRIPLE:-unknown}/" 2>/dev/null || true
    fi
  else
    for t in aarch64-unknown-linux-musl x86_64-unknown-linux-musl aarch64-apple-darwin; do
      for src in "${REPO}/bin/${t}/wist-stackcheck" "${REPO}/tools/stackcheck/target/${t}/release/wist-stackcheck"; do
        if [ -f "${src}" ]; then
          mkdir -p "${STAGE}/bin/${t}"
          cp "${src}" "${STAGE}/bin/${t}/"
          break
        fi
      done
    done
  fi
  find "${STAGE}/bin" -type f -exec chmod 755 {} \; 2>/dev/null || true
}

pack_from_rev() { # $1=rev $2=输出 tar（未压缩）
  git -C "${REPO}" archive --format=tar "$1" -- . ':(exclude).github' >"$2" ||
    die "git archive $1 失败（仓库在 ${REPO}？tag 存在？）"
  # `git archive` 只收**已提交**内容。候选包必须反映工作树，否则预演的是旧代码。
  if [ "$1" = "HEAD" ]; then
    git -C "${REPO}" ls-files -m -o --exclude-standard -z |
      while IFS= read -r -d '' f; do
        [ -f "${REPO}/${f}" ] && tar -rf "$2" -C "${REPO}" "${f}"
      done
  fi
  if [ -d "${STAGE}/bin" ]; then
    tar -rf "$2" -C "${STAGE}" bin
  fi
}

stage_bins

case "${BASELINE}" in
  *.tar.gz)
    [ -f "${BASELINE}" ] || die "找不到基线包：${BASELINE}"
    BASE_PKG="${BASELINE}"
    ;;
  *)
    BASE_PKG="${WORK}/pkg/wist-gateway-stack-${BASELINE}.tar.gz"
    pack_from_rev "${BASELINE}" "${WORK}/pkg/base.tar"
    gzip -9 -c "${WORK}/pkg/base.tar" >"${BASE_PKG}"
    rm -f "${WORK}/pkg/base.tar"
    ;;
esac
ok "基线 ${BASE_PKG}"

if [ -n "${CANDIDATE}" ]; then
  [ -f "${CANDIDATE}" ] || die "找不到候选包：${CANDIDATE}"
  CAND_PKG="${CANDIDATE}"
else
  CAND_VERSION="$(git -C "${REPO}" show HEAD:version.txt 2>/dev/null | tr -d '[:space:]')"
  [ -n "${CAND_VERSION}" ] || die "读不到 ${REPO}/version.txt"
  CAND_PKG="${WORK}/pkg/wist-gateway-stack-v${CAND_VERSION}-alpha.tar.gz"
  pack_from_rev HEAD "${WORK}/pkg/cand.tar"
  gzip -9 -c "${WORK}/pkg/cand.tar" >"${CAND_PKG}"
  rm -f "${WORK}/pkg/cand.tar"
fi
ok "候选 ${CAND_PKG}"

# 两个包里都必须有本机架构的 stackcheck（否则 localize ⓿/⑦ 会回落 cargo run）。
if [ -n "${HOST_TRIPLE}" ]; then
  for pkg in "${BASE_PKG}" "${CAND_PKG}"; do
    if ! tar tzf "${pkg}" | match_out "bin/${HOST_TRIPLE}/wist-stackcheck"; then
      echo "  [WARN] ${pkg##*/} 里没有 ${HOST_TRIPLE} 的 wist-stackcheck；check-stack.sh 会回落 cargo run（本机没 Rust 就会失败）" >&2
    fi
  done
fi

# ── 2. 建工程 + 导入基线 ─────────────────────────────────────────────
say "2) 建工程并导入基线"
PROJ="${WORK}/${PROJ_NAME}"
wipe_dir "${PROJ}"
mkdir -p "${WORK}"
( cd "${WORK}" && gops prj new -n "${PROJ_NAME}" ) >/dev/null || die "gops prj new 失败（旧工程清理干净了吗：${PROJ}）"
cd "${PROJ}" || die "进不去 ${PROJ}"
gops prj import --path "${BASE_PKG}" -f 1 >/dev/null || die "gops prj import 失败"
# 取 `sys:` 块里的第一个 `name:`（项目名也叫 name，不能直接取第一个）
SYS_NAME="$(awk '
  /^[[:space:]]*sys:[[:space:]]*$/ { f = 1; next }
  f && /^[[:space:]]*name:/ {
    sub(/^[[:space:]]*name:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit
  }
' ops-prj.yml)"
[ -n "${SYS_NAME}" ] || SYS_NAME="wist-gateway-stack"
ok "工程 ${PROJ}（系统 ${SYS_NAME}）"

# 用本地包导入会写成 `addr.path`（本地路径）。它是**全量门禁**的检查项，
# 不改的话 0.10.12 之前的门禁会在 ⓿ 就把它拦下（预演跑不下去）。
python3 - "${PROJ}/ops-prj.yml" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(True)
out, in_addr = [], False
for line in lines:
    if line.strip() == "addr:":
        in_addr = True
        out.append(line)
        continue
    if in_addr and line.strip().startswith("path:"):
        out.append(
            "    url: https://rehearsal.invalid/api/v1/releases/artifact/"
            "wist-gateway-stack/v{version}/wist-gateway-stack-v{version}.tar.gz\n"
        )
        in_addr = False
        continue
    out.append(line)
open(p, "w").write("".join(out))
PY
ok "ops-prj.yml 的 addr 已改成 url（避免 ⓿ 门禁误报）"

# ── 3. 站点值（域名 + 错开的端口）────────────────────────────────────
say "3) 写站点值"
VALS="${PROJ}/values/${SYS_NAME}/sys_value.yml"
mkdir -p "$(dirname "${VALS}")"
cat >>"${VALS}" <<EOF
WEB_DOMAIN: ${DOMAIN}
CENTER_API_DOMAIN: center.${DOMAIN}
GIT_PROXY_DOMAIN: git.${DOMAIN}
GATEWAY_PORT: 3443
WEB_PORT: 8443
WPARSE_PORT: 19000
WPARSE_SYSLOG_TCP_PORT: 15141
WPARSE_SYSLOG_UDP_PORT: 15141
WPARSE_ADMIN_PORT: 29090
VM_PORT: 28429
EOF
ok "域名 ${DOMAIN}，端口错开（3443/8443/19000/15141/29090/28429）"

# ── 4. 基线：localize (+ start) ──────────────────────────────────────
say "4) 基线 localize"
( cd "${PROJ}/${SYS_NAME}" && gops sys localize ) >"${WORK}/baseline-localize.log" 2>&1
rc=$?
if [ "${rc}" -ne 0 ]; then
  tail -25 "${WORK}/baseline-localize.log" >&2
  die "基线 localize 失败（日志 ${WORK}/baseline-localize.log）"
fi
ok "基线 localize 通过"

if [ "${SKIP_START}" = 0 ]; then
  say "4b) 基线启动（拉镜像，可能较慢）"
  ( cd "${PROJ}/${SYS_NAME}" && gops run start ) >"${WORK}/baseline-start.log" 2>&1 ||
    { tail -20 "${WORK}/baseline-start.log" >&2; die "基线启动失败"; }
  ok "基线已启动"
else
  ok "跳过基线启动（--skip-start）"
fi

# ── 5. 升级到候选 ───────────────────────────────────────────────────
say "5) 升级到候选包"
( cd "${PROJ}" && gops prj upgrade --to "${CAND_PKG}" ) >"${WORK}/upgrade.log" 2>&1
rc=$?
if [ "${rc}" -ne 0 ]; then
  tail -40 "${WORK}/upgrade.log" >&2
  die "升级失败（日志 ${WORK}/upgrade.log；run 日志见最上面那行 run log）"
fi

# ── 6. 断言 ─────────────────────────────────────────────────────────
say "6) 断言"
RUN_LOG_DIR="$(sed -n 's/^run log: //p' "${WORK}/upgrade.log" | head -1)"
if [ -n "${RUN_LOG_DIR}" ] && [ -d "${RUN_LOG_DIR}" ]; then
  REGEN="$(ls "${RUN_LOG_DIR}"/02-regenerate-*.log 2>/dev/null | head -1)"
  if [ -n "${REGEN}" ]; then
    # ⓿ 只应看到 prereq.*；出现 ops-prj./secrets.* 说明 `--only` 没过滤本地门禁。
    if grep -qE "^(\\[FAIL\\])?[[:space:]]*(secrets\\.|ops-prj\\.)" "${REGEN}"; then
      die "⓿ 出现非 prereq 判据（--only 没有生效）：$(grep -E 'secrets\\.|ops-prj\\.' "${REGEN}" | head -2)"
    fi
    ok "⓿ 只跑了 prereq 判据"
    grep -q "全部对齐" "${REGEN}" || die "⑥ perms 没有收敛到「全部对齐」（见 ${REGEN}）"
    ok "⑥ perms 全部对齐"
    if grep -q "\\[FAIL\\]" "${REGEN}"; then
      grep -A2 "\\[FAIL\\]" "${REGEN}" | head -10 >&2
      die "⑦ 全量门禁有 FAIL（见 ${REGEN}）"
    fi
    ok "⑦ 全量门禁无 FAIL"
  fi
fi

STATUS="$(python3 - <<PY
import json
print(json.load(open("${HOME}/.galaxy/upgrade/${PROJ_NAME}/upgrade.json"))["status"])
PY
)" || STATUS=""
[ "${STATUS}" = "succeeded" ] || die "upgrade.json status=${STATUS:-<读不到>}（期望 succeeded）"
ok "upgrade.json status=succeeded"

VER="$(tr -d '[:space:]' <"${PROJ}/${SYS_NAME}/version.txt")"
ok "部署版本 ${VER}"
[ "$(cd "${PROJ}/${SYS_NAME}" && gops sys perms --check >/dev/null 2>&1; echo $?)" = 0 ] ||
  die "升级后 perms --check 不通过（cd ${PROJ}/${SYS_NAME} && gops sys perms --check 看明细）"
ok "perms --check 通过"

SEC="${PROJ}/${SYS_NAME}/.wist/sec-value.yml"
if [ -f "${SEC}" ]; then
  SEC_INFO="$(stat -c '%a %U:%G' "${SEC}")"
  ok "密钥 ${SEC_INFO}"
fi

RUNNING="$(docker ps --filter "name=wist-gateway-stack-" --format '{{.Names}}' | wc -l | tr -d ' ')"
[ "${RUNNING}" -gt 0 ] || die "没有容器在跑"
ok "运行中的容器 ${RUNNING} 个"

# ── 7. 收尾 ─────────────────────────────────────────────────────────
say "7) 结果"
printf '  基线 %s → 候选 %s\n' "${BASE_PKG##*/}" "${CAND_PKG##*/}"
printf '  工程 %s（日志：%s）\n' "${PROJ}" "${WORK}"
if [ "${CLEAN}" = 1 ]; then
  ( cd "${PROJ}/${SYS_NAME}" 2>/dev/null && gops run stop >/dev/null 2>&1 ) || true
  wipe_dir "${PROJ}"
  echo "  已清理 ${PROJ}（镜像保留）"
else
  echo "  保留现场。清理：cd ${PROJ}/${SYS_NAME} && gops run stop; sudo rm -rf ${PROJ}"
fi
echo
echo "预演通过：新包的门禁没有拦下自己的升级。"
