#!/usr/bin/env bash
# WarpParse 管理面备料（由 localize 阶段流程调用，幂等）。
#
# 做的事：
#   1) 建可写运行根 data-plane-run/work 与运行态目录；
#   2) 生成 admin API bearer token → data-plane-run/.run/admin_api.token.host（缺失才生成）；
#   3) 创建并初始化 wparse 运行态命名卷（wist-gateway-stack-wparse-run，999:999 / 2770）。
#
# 为什么不把 token 直接放 bind 挂载的 .run/：
#   · WarpParse 要求 token 文件 **0600 且属主=运行用户**；
#   · `gops sys perms` 会把 bind 挂载里的文件统一成 0660（owner=部署账号、group=999）；
#   · 两者冲突。因此容器内 token 放在**命名卷**，由 wparse-run-init 以 999 身份复制并 chmod 600；
#     宿主这份 `.host` 属主=部署账号、0600，留给 gwlinkd 读。
set -euo pipefail

# `set -e` 的静默退出是排查黑洞：脚本半途死掉、stderr 空白。
# 任何未被 if/&& 接住的失败都把行号打到 stderr。
# 为什么用 $0 / $? 而不用中间变量：`$(basename "$0")` 是**命令替换**，
# 在同一个字符串里先展开它会把 `$?` 冲成 0（已实测），行号与退出码就都错了。
trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_DIR="${STACK_ROOT}/data-plane-run"
TOKEN_HOST="${RUN_DIR}/.run/admin_api.token.host"
LEGACY_TOKEN="${RUN_DIR}/.run/admin_api.token"
VOLUME="${WPARSE_RUN_VOLUME:-wist-gateway-stack-wparse-run}"
IMAGE="${WARP_SPC:-ghcr.io/wp-labs}/warp-parse:${WPARSE_TAG:-0.32.1-alpha}"

# 显式按**宿主架构**钉平台：镜像源里可能只有单一架构（如从 Apple Silicon 用 push-images.sh
# 的 pull 方式推成 arm64-only），本地也可能缓存了异架构的同名 tag。此时 `docker run` 直接
# `exec format error`，报错完全不指向「镜像架构不对」这个真正原因。
HOST_PLATFORM=""
case "$(uname -m)" in
  x86_64 | amd64) HOST_PLATFORM="linux/amd64" ;;
  aarch64 | arm64) HOST_PLATFORM="linux/arm64" ;;
esac
PLATFORM_ARG="${HOST_PLATFORM:+--platform ${HOST_PLATFORM}}"

note() { echo "  $*"; }
warn() { echo "  ⚠ $*" >&2; }

mkdir -p "${RUN_DIR}/work" "${RUN_DIR}/.run" "${RUN_DIR}/data"

# 预建 `work/` 里的**嵌套挂载点**：`/data/data`（bind）、`/data/.run`（命名卷）、
# `/data/identity/{admin-tls.*.pem,trust}`（文件与目录挂载）。
#
# 为什么必须在这里建：父挂载 `${WPARSE_RUN_WORK}:/data` 生效后，子挂载点只能落在
# **宿主**这份工作目录里；缺失时由 Docker 守护进程以 **root** 创建（空目录/空文件）。
# 一旦如此，部署账号既 chown 不动也 chmod 不动 → `gops sys perms --apply` 只会得到
# 整片 `Operation not permitted`（属主 0:999），只能管理员 `sudo chown -R` 收拾。
# 本脚本以部署账号跑，提前建好，Docker 看到已存在就不会再创建。
NESTED_MOUNTS=(
  "${RUN_DIR}/work/data"
  "${RUN_DIR}/work/.run"
  "${RUN_DIR}/work/identity"
  "${RUN_DIR}/work/identity/trust"
)
mkdir -p "${NESTED_MOUNTS[@]}"
NESTED_FILES=(
  "${RUN_DIR}/work/identity/admin-tls.crt.pem"
  "${RUN_DIR}/work/identity/admin-tls.key.pem"
)
for path in "${NESTED_FILES[@]}"; do
  # 旧现场可能因「源缺失」被 Docker 把挂载点建成同名**目录**（与 0.2.9 信任锚同一个坑）：
  # 空的直接清掉（只删空目录），非空的不碰，交给人确认。
  if [[ -d "${path}" ]]; then
    if rmdir "${path}" 2>/dev/null; then
      warn "清掉 Docker 留下的空目录挂载点：${path}"
    else
      warn "${path} 是目录且非空（Docker 残留？），请手工确认后删除，再重跑 localize"
      continue
    fi
  fi
  : >>"${path}"
done

# 老现场（本脚本这一步之前建成的）可能已被 root 占有：非 root 改不动，只能请管理员一次性修。
# ⚠ 只能 chown **这些路径**：工作根里 conf/connectors/models/topology 是容器自己的，
#    0.2.12 之前的入口用 `cp -a` 补种子（需要目录属主是容器用户），整棵 chown 会把它弄挂。
foreign=()
for path in "${NESTED_MOUNTS[@]}" "${NESTED_FILES[@]}"; do
  if [[ -e "${path}" && ! -O "${path}" ]]; then
    foreign+=("${path}")
  fi
done
if (( ${#foreign[@]} > 0 )); then
  warn "这些挂载点/文件的属主不是当前部署账号（多由 Docker 以 root 创建）："
  for path in "${foreign[@]}"; do
    warn "  ${path}"
  done
  warn "  一次性修复（管理员，只对这些路径）："
  for path in "${foreign[@]}"; do
    warn "    sudo chown -R $(id -u):999 ${path}"
  done
  warn "  再跑一次 'gops sys perms --apply' 把模式收成 0660/2770"
fi

# ── WarpParse 0.34+ 迁移：工作根里的旧模板带 `[admin_api.auth] mode`，而 0.34 起
#    这个字段从 schema 里删了 —— 引擎当成 unknown field，配置加载失败（exit 300；
#    容器退出码被截成 8 位 = 44），表现是“wparse 无限重启、日志只有一句 load conf failed”。
#
#    为什么升级不会自动好：容器入口是 `cp --update=none`，工作根里**已存在**的旧文件永远不覆盖。
#    两处都要处理，且不能粗暴覆盖（站点可能改过端口 / TLS）：
#      · `wparse.local.toml`：只摘掉 `[admin_api.auth]` 段里的 `mode` 行；
#      · `conf/wparse.toml`：旧模板整段带 `[admin_api]` → 用种子覆盖（先备份）。
migrate_wparse_admin_conf() {
  local root="$1"
  [[ -d "${root}" ]] || return 0

  local local_conf="${root}/wparse.local.toml"
  if [[ -f "${local_conf}" ]]; then
    python3 - "${local_conf}" <<'PY'
import os, re, sys, pathlib

path = pathlib.Path(sys.argv[1])
mode = path.stat().st_mode & 0o7777
out, section, removed = [], None, 0
for line in path.read_text(encoding="utf-8").splitlines():
    stripped = line.strip()
    if stripped.startswith("["):
        section = stripped
    elif section == "[admin_api.auth]" and re.match(r"^[ \t]*mode[ \t]*=", line):
        removed += 1
        continue
    out.append(line)
if removed:
    target = path.with_name(path.name + ".tmp")
    target.write_text("\n".join(out) + "\n", encoding="utf-8")
    os.chmod(target, mode)
    target.replace(path)
    print(f"  已从 {path} 摘掉 {removed} 行 [admin_api.auth].mode（wparse 0.34 起不再接受）")
PY
  fi

  local conf="${root}/conf/wparse.toml"
  local seed="${STACK_ROOT}/sys/data-plane/conf/wparse.toml"
  if [[ -f "${conf}" && -f "${seed}" ]] && grep -q '^\[admin_api' "${conf}"; then
    local backup="${conf}.legacy-admin-api.bak"
    cp -f "${conf}" "${backup}"
    cp -f "${seed}" "${conf}"
    note "工作根 conf/wparse.toml 是旧模板（含 [admin_api]），已用种子覆盖（备份：${backup}）"
  fi
}

migrate_wparse_admin_conf "${RUN_DIR}/work"
# 开发态（如果这台机器上还有）：同一份种子，同样的迁移。
migrate_wparse_admin_conf "${RUN_DIR}/dev"

# ── 域名映射守卫（extra_hosts 口径）──
# `CENTER_API_DOMAIN` / `GIT_PROXY_DOMAIN` **只**用于 `extra_hosts`：单机部署时把域名在
# wparse 容器里指回宿主。它们的失败方式是**静默**的 —— compose 退化成 `<name>.invalid`
# 这条无效映射，容器里域名解析照样失败，只是失败点挪到了 `git clone` / 升级里。
# 所以两件最容易犯的错在这里当场拦：
#   1) 旧键 `CENTER_DOMAIN` 没改名（gops 对 values 未知键静默接受，旧键只会进 .env 不报错）；
#   2) 映射的域名与容器真正要访问的主机名不一致（典型：dev 的 values 被抄到生产）。
if [[ -n "${CENTER_DOMAIN:-}" && -z "${CENTER_API_DOMAIN:-}" ]]; then
  echo "错误：CENTER_DOMAIN 已改名为 CENTER_API_DOMAIN（0.6.0-alpha 起）。" >&2
  echo "      gops 对 values 的未知键不报错，旧键会静默失效（extra_hosts 退化成 center.invalid）。" >&2
  echo "      处置：把 values 里的 CENTER_DOMAIN: 改成 CENTER_API_DOMAIN: 后重跑 localize。" >&2
  exit 1
fi

# URL → 主机名（去 scheme / 路径 / 端口）。只要有 https:// 或 host:port 这种形状就够用，
# 没引 bashism 之外的依赖。
url_host() {
  local url="$1"
  url="${url#*://}"
  url="${url%%/*}"
  printf '%s' "${url%%:*}"
}

# 映射的域名必须正是那个要访问的域名，否则这条映射一无是处（换成 IP 也不该改这里）。
check_host_mapping() {
  local var="$1" mapped="$2" ref_var="$3" url="$4" host=""
  if [[ -z "${mapped}" || -z "${url}" ]]; then
    return 0
  fi
  host="$(url_host "${url}")"
  if [[ -n "${host}" && "${host}" != "${mapped}" ]]; then
    warn "${var}=${mapped} 与 ${ref_var} 的主机名 ${host} 不一致：这条映射对容器无效（从别的现场抄了 values？）"
  fi
}

check_host_mapping CENTER_API_DOMAIN "${CENTER_API_DOMAIN:-}" CENTER_ENDPOINT \
  "${CENTER_ENDPOINT:-${GWLINKD_CENTER_ENDPOINT:-}}"
check_host_mapping GIT_PROXY_DOMAIN "${GIT_PROXY_DOMAIN:-}" WPARSE_PROJECT_MODELS_REPO \
  "${WPARSE_PROJECT_MODELS_REPO:-}"
check_host_mapping GIT_PROXY_DOMAIN "${GIT_PROXY_DOMAIN:-}" WPARSE_PROJECT_INFRA_REPO \
  "${WPARSE_PROJECT_INFRA_REPO:-}"

# ── Git 客户端身份（双向证书）──
# wparse 用 **libgit2**（静态链接，容器里根本没 git 二进制），所以 `GIT_SSL_CERT` /
# `GIT_SSL_KEY` 这类 **git CLI 专属**变量无效。libgit2 只认 gitconfig 的 `http.sslCert/sslKey`，
# 但 **当前 wparse 并不读 gitconfig**（实测：把 sslCAInfo 写坏也照样拉成功）——
# 客户端证书需要 wparse 上游支持。这里先把证书物化好（0600），上游支持后直接用。
CRED="${STACK_ROOT}/identity/gwlinkd/credential.json"
GIT_CERT_HOST="${RUN_DIR}/.run/git-client.crt.host"
GIT_KEY_HOST="${RUN_DIR}/.run/git-client.key.host"

if [[ -f "${CRED}" ]]; then
  tmp_crt="$(mktemp "${RUN_DIR}/.run/.git-client.crt.host.XXXXXX")"
  tmp_key="$(mktemp "${RUN_DIR}/.run/.git-client.key.host.XXXXXX")"
  python3 - "${CRED}" "${tmp_crt}" "${tmp_key}" <<'PY'
import json
import sys

src, crt_path, key_path = sys.argv[1:4]
with open(src, encoding="utf-8") as handle:
    data = json.load(handle)
bundle = data.get("bundle") or {}
cert = bundle.get("certificate") or ""
key = data.get("private_key_pem") or ""
if "BEGIN CERTIFICATE" not in cert or "PRIVATE KEY" not in key:
    raise SystemExit("credential.json 缺 certificate / private_key_pem")
for path, pem in ((crt_path, cert), (key_path, key)):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(pem if pem.endswith("\n") else pem + "\n")
PY
  chmod 600 "${tmp_crt}" "${tmp_key}"
  for pair in "${tmp_crt}:${GIT_CERT_HOST}" "${tmp_key}:${GIT_KEY_HOST}"; do
    src_file="${pair%%:*}"
    dst_file="${pair##*:}"
    if [[ -f "${dst_file}" ]] && cmp -s "${src_file}" "${dst_file}"; then
      rm -f "${src_file}"
    else
      mv -f "${src_file}" "${dst_file}"
      note "已更新 Git 客户端证书（宿主侧）：${dst_file}"
    fi
  done
else
  warn "缺 ${CRED}（网关未入网？）：跳过客户端证书投影"
  rm -f "${GIT_CERT_HOST}" "${GIT_KEY_HOST}"
fi

if [[ -f "${TOKEN_HOST}" && -s "${TOKEN_HOST}" ]]; then
  note "admin API token 已存在，跳过：${TOKEN_HOST}"
else
  tmp="$(mktemp "${RUN_DIR}/.run/.admin_api.token.host.XXXXXX")"
  if [[ -s "${LEGACY_TOKEN}" ]]; then
    # 迁移：旧脚本把 token 直接写在 bind 挂载的 .run/ 里。
    cp -f "${LEGACY_TOKEN}" "${tmp}"
  else
    python3 -c 'import secrets; print(secrets.token_hex(32))' >"${tmp}"
  fi
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${TOKEN_HOST}"
  note "已生成 admin API token（宿主侧）：${TOKEN_HOST}"
fi

if ! command -v docker >/dev/null 2>&1; then
  warn "找不到 docker：跳过运行态命名卷初始化（首次 start 前需手动执行）"
  exit 0
fi

if ! docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
  docker volume create "${VOLUME}" >/dev/null
  note "已创建运行态命名卷：${VOLUME}"
fi

# 命名卷默认 root:root；wparse 以 999 运行，需要可写。
if ! docker run --rm -u 0:0 ${PLATFORM_ARG} -v "${VOLUME}:/run" --entrypoint /bin/sh "${IMAGE}" \
  -c 'chown 999:999 /run && chmod 2770 /run' >/dev/null; then
  warn "运行态命名卷初始化失败：${IMAGE}（宿主平台 ${HOST_PLATFORM:-未知}）"
  warn "常见原因：该 tag 在镜像源里缺宿主架构（arm64-only 镜像跑在 amd64 宿主）——"
  warn "  用 ./dev/push-images.sh 重新同步（buildx imagetools 保留多架构），或把 WARP_SPC 指回 ghcr.io/wp-labs"
  exit 1
fi
note "运行态命名卷已对齐 999:999 / 2770：${VOLUME}"

note "WarpParse 管理面：容器 0.0.0.0:19090 + TLS；宿主仅 127.0.0.1:${WPARSE_ADMIN_PORT:-19090}"
note "gwlinkd 读取的 token：${TOKEN_HOST}（0600）"
