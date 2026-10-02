#!/usr/bin/env bash
# `scripts/align-host-perms.sh` 的回归测试：在**一次性 Linux 容器**里验证属主/属组/setgid 语义与可达性。
#
# 为什么必须换到 Linux 跑：这套语义（bind 挂载不改属主、setgid 继承、组权限、chgrp 的权限要求）
# **只在 Linux 上发生**，而开发机多为 macOS —— OrbStack/Docker Desktop 的挂载不校验属主，
# align 脚本在那里是直接跳过的。所以回归只能借容器换内核。
#
# 隔离承诺：数据全部建在容器内 `/tmp`（不 bind mount 宿主目录，免得 macOS 那侧对属主的模拟干扰），
# 只把本测试与 align 脚本**只读**挂进去；用完即销毁，不碰任何既有容器 / 卷 / 网络。
#
# 用法（开发机，需要 docker）：
#   dev/tests/align-host-perms.test.sh                 # 默认 ubuntu:24.04
#   TEST_IMAGE=debian:12 dev/tests/align-host-perms.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
ALIGN="${STACK_ROOT}/scripts/align-host-perms.sh"
TEST_IMAGE="${TEST_IMAGE:-ubuntu:24.04}"

if [[ -z "${ALIGN_TEST_IN_CONTAINER:-}" ]]; then
  [[ -f "${ALIGN}" ]] || { echo "找不到 ${ALIGN}" >&2; exit 1; }
  command -v docker >/dev/null 2>&1 || { echo "需要 docker 才能跑这个测试" >&2; exit 1; }
  echo "在一次性容器里跑（image=${TEST_IMAGE}；只读挂入测试与脚本，数据在容器内 /tmp）"
  exec docker run --rm -e ALIGN_TEST_IN_CONTAINER=1 \
    -v "${SELF}:/t/test.sh:ro" \
    -v "${ALIGN}:/t/align-host-perms.sh:ro" \
    "${TEST_IMAGE}" bash /t/test.sh
fi

# ─────────────────────────── 以下在容器内（真 Linux）执行 ───────────────────────────
# 关掉 -e：本测试里有大量**预期失败**的调用（读被拒、退出码非 0），由 chk/chk_nz 自己判断。
set +e
ALIGN=/t/align-host-perms.sh
ROOT=/tmp/site
DEPLOY_UID=1000   # 部署账号
DEPLOY_GID=1000
CONT_GID=999      # 容器内 gateway/wparse 的运行身份（compose 里钉的）
OTHER_UID=1001    # 无关宿主账号
fail=0

command -v setpriv >/dev/null 2>&1 || { echo "缺 setpriv（util-linux），无法切身份测试" >&2; exit 1; }

chk() { # chk <描述> <期望> <实际>
  if [[ "$2" == "$3" ]]; then
    echo "  [OK]   $1"
  else
    echo "  [FAIL] $1（期望 $2，实际 $3）"
    fail=1
  fi
}
chk_nz() { # chk_nz <描述> <实际>：只要非 0 就算通过
  if [[ "$2" != "0" ]]; then
    echo "  [OK]   $1（被拒，rc=$2）"
  else
    echo "  [FAIL] $1（期望被拒，实际成功）"
    fail=1
  fi
}
st() { stat -c '%u:%g:%a' "$1" 2>/dev/null || echo '缺失'; }
as() { # as <uid> <cmd...>：以某个 uid/gid 跑（清掉附加组，模拟容器进程的组身份）
  local uid="$1"; shift
  setpriv --reuid="${uid}" --regid="${uid}" --clear-groups "$@"
}
align_as_root() { # 模拟 `sudo ./scripts/align-host-perms.sh`：euid=0，但属主取 SUDO_UID/SUDO_GID
  env SUDO_UID="${DEPLOY_UID}" SUDO_GID="${DEPLOY_GID}" CONTAINER_GID="${CONT_GID}" bash "${ALIGN}" "$@"
}
seed_site() { # 一个「全新机器」的现场：部署账号拥有、最小权限
  rm -rf "${ROOT}"
  mkdir -p "${ROOT}/configs/gateway/state" "${ROOT}/data-plane-run"
  printf -- '-----BEGIN PRIVATE KEY-----\nx\n' > "${ROOT}/configs/gateway/state/gateway-ca.key.pem"
  printf 'admin_api_token = "s"\n' > "${ROOT}/configs/gateway/wist-gateway.toml"
  chown -R "${DEPLOY_UID}:${DEPLOY_GID}" "${ROOT}"
  chmod 600 "${ROOT}/configs/gateway/state/gateway-ca.key.pem"
  chmod 644 "${ROOT}/configs/gateway/wist-gateway.toml"
  chmod 755 "${ROOT}/configs/gateway" "${ROOT}/configs/gateway/state" "${ROOT}/data-plane-run"
}

echo "== 1) 全新现场 → 对齐（模拟 sudo：euid=0，属主仍取部署账号）=="
seed_site
align_as_root "${ROOT}" || fail=1
chk "data-plane-run/.run 属主:属组" "1000:999" "$(st "${ROOT}/data-plane-run/.run" | cut -d: -f1,2)"
chk "data-plane-run/.run 权限" "2770" "$(st "${ROOT}/data-plane-run/.run" | cut -d: -f3)"
chk "data-plane-run/data 权限" "2770" "$(st "${ROOT}/data-plane-run/data" | cut -d: -f3)"
chk "packages 权限" "2770" "$(st "${ROOT}/packages" | cut -d: -f3)"
chk "configs/gateway 权限" "2770" "$(st "${ROOT}/configs/gateway" | cut -d: -f3)"
chk "configs/gateway/state 权限" "2770" "$(st "${ROOT}/configs/gateway/state" | cut -d: -f3)"
chk "私钥 属组:权限（600→640）" "999:640" "$(st "${ROOT}/configs/gateway/state/gateway-ca.key.pem" | cut -d: -f2,3)"
chk "toml 属组:权限（644→640）" "999:640" "$(st "${ROOT}/configs/gateway/wist-gateway.toml" | cut -d: -f2,3)"

echo "== 2) 容器身份 999:999：写运行目录 / 建库 / 读私钥与 toml =="
as "${CONT_GID}" touch "${ROOT}/data-plane-run/.run/.wparse.lock"; chk "999 建 .wparse.lock" "0" "$?"
chk "  锁文件属组=999（setgid 继承）" "999" "$(st "${ROOT}/data-plane-run/.run/.wparse.lock" | cut -d: -f2)"
as "${CONT_GID}" sh -c "printf x > ${ROOT}/configs/gateway/state/store.db"; chk "999 在 state/ 建 store.db" "0" "$?"
as "${CONT_GID}" cat "${ROOT}/configs/gateway/state/gateway-ca.key.pem" >/dev/null; chk "999 读私钥" "0" "$?"
as "${CONT_GID}" cat "${ROOT}/configs/gateway/wist-gateway.toml" >/dev/null; chk "999 读 toml" "0" "$?"

echo "== 3) 部署账号 1000:1000：能读私钥（备份/恢复不需提权）、能改配置 =="
as "${DEPLOY_UID}" cat "${ROOT}/configs/gateway/state/gateway-ca.key.pem" >/dev/null; chk "1000 读私钥" "0" "$?"
as "${DEPLOY_UID}" sh -c "printf 'x' >> ${ROOT}/configs/gateway/wist-gateway.toml"; chk "1000 改 toml" "0" "$?"

echo "== 4) 无关宿主账号 1001：读不到私钥、连 state/ 都进不去 =="
as "${OTHER_UID}" cat "${ROOT}/configs/gateway/state/gateway-ca.key.pem" >/dev/null 2>&1; chk_nz "1001 读私钥被拒" "$?"
as "${OTHER_UID}" ls "${ROOT}/configs/gateway/state" >/dev/null 2>&1; chk_nz "1001 进不去 state/" "$?"

echo "== 5) 幂等：部署账号（**不提权**）再跑 → 不写盘、exit 0 =="
out="$(as "${DEPLOY_UID}" env CONTAINER_GID="${CONT_GID}" bash "${ALIGN}" "${ROOT}" 2>&1)"; rc=$?
chk "已对齐时无权限也 exit 0" "0" "${rc}"
echo "     ${out}"

echo "== 6) 需提权但无权：给出可执行命令、exit 1（ALIGN_NO_SUDO 关掉自动提权）=="
as "${DEPLOY_UID}" sh -c "chmod 755 ${ROOT}/data-plane-run/.run"
out="$(as "${DEPLOY_UID}" env ALIGN_NO_SUDO=1 CONTAINER_GID="${CONT_GID}" bash "${ALIGN}" "${ROOT}" 2>&1)"; rc=$?
chk "无权时 exit 1" "1" "${rc}"
case "${out}" in
  *"sudo ${ALIGN}"*) echo "  [OK]   打印了 sudo 可执行命令" ;;
  *) echo "  [FAIL] 没打印 sudo 命令：${out}"; fail=1 ;;
esac
align_as_root "${ROOT}" >/dev/null || fail=1

echo "== 7) setgid 继承 + 600→640 闭环 =="
as "${DEPLOY_UID}" sh -c "printf x > ${ROOT}/configs/gateway/state/fresh.key.pem; chmod 600 ${ROOT}/configs/gateway/state/fresh.key.pem"
chk "新文件属组=999（setgid）" "999" "$(st "${ROOT}/configs/gateway/state/fresh.key.pem" | cut -d: -f2)"
as "${CONT_GID}" cat "${ROOT}/configs/gateway/state/fresh.key.pem" >/dev/null 2>&1; chk_nz "600 容器读不到（预期）" "$?"
align_as_root "${ROOT}" >/dev/null || fail=1
chk "align 后 640" "999:640" "$(st "${ROOT}/configs/gateway/state/fresh.key.pem" | cut -d: -f2,3)"
as "${CONT_GID}" cat "${ROOT}/configs/gateway/state/fresh.key.pem" >/dev/null; chk "640 容器读得到" "0" "$?"

echo "== 8) 参数/边界：gid 非数字、目标路径是文件 =="
env CONTAINER_GID=wist bash "${ALIGN}" "${ROOT}" >/dev/null 2>&1; chk "CONTAINER_GID 非数字 → 明确报错、exit 1" "1" "$?"
rm -rf "${ROOT}/configs/web"; printf x > "${ROOT}/configs/web"
out="$(align_as_root "${ROOT}" 2>&1)"; rc=$?
chk "目标路径是文件 → 明确报错、exit 1" "1" "${rc}"
case "${out}" in
  *"configs/web"*"不是目录"*) echo "  [OK]   报错点明了路径与原因" ;;
  *) echo "  [FAIL] 报错不够明确：${out}"; fail=1 ;;
esac
rm -f "${ROOT}/configs/web"

echo "== 9) SQLite 库：恢复搬来的放开到属组 rw；容器自建的不动 ="
# (a) 「恢复搬过来」的库：属主=部署账号、属组不是容器、644 → 容器只能读、不能写（现场即 code 14 那类失败）
printf x > "${ROOT}/configs/gateway/state/wist-gateway.db"
chown "${DEPLOY_UID}:${DEPLOY_GID}" "${ROOT}/configs/gateway/state/wist-gateway.db"
chmod 644 "${ROOT}/configs/gateway/state/wist-gateway.db"
as "${CONT_GID}" sh -c "printf y >> ${ROOT}/configs/gateway/state/wist-gateway.db" 2>/dev/null
chk_nz "恢复来的库：容器写不了（预期）" "$?"
align_as_root "${ROOT}" >/dev/null || fail=1
chk "align 后 属主:属组:权限" "1000:999:660" "$(st "${ROOT}/configs/gateway/state/wist-gateway.db")"
as "${CONT_GID}" sh -c "printf y >> ${ROOT}/configs/gateway/state/wist-gateway.db"; chk "容器可写库" "0" "$?"
as "${DEPLOY_UID}" cat "${ROOT}/configs/gateway/state/wist-gateway.db" >/dev/null; chk "部署账号仍可读库（备份）" "0" "$?"
# (b) 容器自己建的库（999:999 644）：属主位已足够，**不能**算作待修 —— 否则每次 localize 都要 sudo
rm -f "${ROOT}/configs/gateway/state/wist-gateway.db"
printf x > "${ROOT}/configs/gateway/state/wist-gateway.db"
chown "${CONT_GID}:${CONT_GID}" "${ROOT}/configs/gateway/state/wist-gateway.db"
chmod 644 "${ROOT}/configs/gateway/state/wist-gateway.db"
out="$(as "${DEPLOY_UID}" env ALIGN_NO_SUDO=1 CONTAINER_GID="${CONT_GID}" bash "${ALIGN}" "${ROOT}" 2>&1)"; rc=$?
chk "容器自建的库不算待修（无权限也 exit 0）" "0" "${rc}"
chk "  → 原样保留，未被改写" "999:999:644" "$(st "${ROOT}/configs/gateway/state/wist-gateway.db")"

echo
if [[ "${fail}" == "0" ]]; then echo "全部通过"; else echo "存在失败项"; fi
exit "${fail}"
