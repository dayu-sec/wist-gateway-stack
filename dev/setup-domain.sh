#!/usr/bin/env bash
# 把网关切到某个域名（域名 = 网关的身份）。
#
# 做四件事：
#   1. 建/复用一张小 CA（共享身份 identity/gateway/{public,private}/gateway-ca.*）—— 它成为 agent 的信任锚；
#   2. 用这张 CA 签一张叶证书，SAN 含新域名（以及传入的旧域名、localhost、127.0.0.1）；
#   3. 改写配置的 listen_addr / public_base_url / [agent] trust_bundle_file ——
#      其它字段一律不动，尤其**不碰 admin_api_token**（所以这里绝不调用 `wist-gateway init-config`，
#      它会整份重写配置并换掉 token）；
#   4. 打印自检命令与影响面（已装 agent 要不要重跑安装）。
#
# 为什么要先建 CA：信任锚是「自签叶证书」时，换域名 = 换锚 = 所有 agent 必须重装；
# 锚换成 CA 根之后，换域名只是重签一张叶证书，agent 侧完全无感。
#
# 用法：
#   ./dev/setup-domain.sh <新域名> [旧域名…]
#     ./dev/setup-domain.sh c-dev01.test.gw.jingang.cloud
#     ./dev/setup-domain.sh c-dev02.test.gw.jingang.cloud c-dev01.test.gw.jingang.cloud
#
# 可覆盖 env：
#   WIST_GATEWAY_HOME  网关持久目录（默认 <栈根>/dev/configs/gateway；发布态另用 <栈根>/configs/gateway）
#   GATEWAY_LISTEN     监听地址（默认 0.0.0.0:443；443 是特权端口，起服务要 root）
#   GATEWAY_URL_PORT   对外基址里的端口；未设置时按 GATEWAY_LISTEN 推导（443 就不带端口）；
#                      显式设成空串（GATEWAY_URL_PORT=）＝ 一定不带端口（前面挂反代时用）
#   DRY_RUN=1          只打印将要做的改动，不落任何文件
#
# 可选 flag：
#   --keep-listen      保留配置里现有的 listen_addr
#   --no-ca            不建 CA，仍用叶证书当信任锚（一次性场合；换域名要重装 agent）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)" # 本脚本在 dev/ 下：栈根 = 上一层

GW_HOME="${WIST_GATEWAY_HOME:-${SCRIPT_DIR}/configs/gateway}"
CONFIG="${GW_HOME}/wist-gateway.toml"
STATE_DIR="${GW_HOME}/state"
# 站点身份（CA/证书/私钥）放**栈根** `identity/`，dev 与发布态共用同一份 —— 不再随各态的 state/ 走。
# 配置里写相对配置目录的路径（identity/public|private/...），靠 GW_HOME 下的 identity symlink 落到这里。
GW_IDENTITY="${STACK_ROOT}/identity/gateway"
IDENTITY_PUBLIC="${GW_IDENTITY}/public"
IDENTITY_PRIVATE="${GW_IDENTITY}/private"
IDENTITY_LINK="${GW_HOME}/identity"
GATEWAY_LISTEN="${GATEWAY_LISTEN:-0.0.0.0:443}"
DRY_RUN="${DRY_RUN:-0}"

LISTEN_OVERRIDE="${GATEWAY_LISTEN}"
USE_CA=1
KEEP_LISTEN=0
DOMAINS=()

usage() {
  cat <<'EOF'
用法：./dev/setup-domain.sh <新域名> [旧域名…]
      ./dev/setup-domain.sh c-dev01.test.gw.jingang.cloud
      ./dev/setup-domain.sh c-dev02.test.gw.jingang.cloud c-dev01.test.gw.jingang.cloud
可选 flag：--keep-listen（保留现有监听）  --no-ca（不建 CA，叶证书当锚）
可覆盖 env：WIST_GATEWAY_HOME / GATEWAY_LISTEN / GATEWAY_URL_PORT / DRY_RUN=1
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

for arg in "$@"; do
  case "${arg}" in
    -h | --help)
      usage
      exit 0
      ;;
    --keep-listen)
      KEEP_LISTEN=1
      ;;
    --no-ca)
      USE_CA=0
      ;;
    -*)
      usage >&2
      die "未知参数 ${arg}"
      ;;
    *)
      DOMAINS+=("${arg}")
      ;;
  esac
done

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  usage >&2
  die "至少要给一个新域名"
fi

PRIMARY="${DOMAINS[0]}"
for name in "${DOMAINS[@]}"; do
  # 名字会进证书 SAN 与配置里的 URL：只允许域名/主机名允许的字符，避免拼出坏证书或坏 URL。
  if [[ ! "${name}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    die "域名看起来不合法：${name}"
  fi
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

require_cmd openssl
require_cmd python3

[[ -f "${CONFIG}" ]] || die "找不到网关配置：${CONFIG}
先跑 ./dev/svc.sh start gateway 生成配置（**别**手跑 init-config：它会换掉 admin token）"
mkdir -p "${IDENTITY_PUBLIC}" "${IDENTITY_PRIVATE}"

# ── 监听与对外基址 ────────────────────────────────────────────────────────────
# 对外基址里的端口：未显式设置时按监听端口推导 —— 443 是默认端口，不写出来更标准；
# 别的端口必须写出来，否则 agent 会去连 443。
if [[ -n "${GATEWAY_URL_PORT+x}" ]]; then
  URL_PORT="${GATEWAY_URL_PORT}"
else
  LISTEN_PORT="${LISTEN_OVERRIDE##*:}"
  if [[ "${LISTEN_PORT}" == "443" ]]; then
    URL_PORT=""
  else
    URL_PORT="${LISTEN_PORT}"
  fi
fi

if [[ -n "${URL_PORT}" ]]; then
  PUBLIC_BASE_URL="https://${PRIMARY}:${URL_PORT}"
else
  PUBLIC_BASE_URL="https://${PRIMARY}"
fi

if [[ "${KEEP_LISTEN}" == "1" ]]; then
  # 保留监听：把当前值原样传下去，python 侧就不会改这一行。
  LISTEN_VALUE="__KEEP__"
else
  LISTEN_VALUE="${LISTEN_OVERRIDE}"
fi

# ── 证书 ──────────────────────────────────────────────────────────────────────
# 证书/私钥一律落**共享身份**（而不是 dev home 的 state/）：公开证书/锚进 public，私钥进 private。
CA_KEY="${IDENTITY_PRIVATE}/gateway-ca.key.pem"
CA_CRT="${IDENTITY_PUBLIC}/gateway-ca.crt.pem"
LEAF_KEY="${IDENTITY_PRIVATE}/admin-tls.key.pem"
LEAF_CRT="${IDENTITY_PUBLIC}/admin-tls.crt.pem"
LEAF_EXT="${IDENTITY_PRIVATE}/.admin-tls.ext" # 临时扩展文件：用隐藏名，别留垃圾

note() {
  echo "  $*"
}

if [[ "${DRY_RUN}" != "1" ]]; then
  # 让 dev home 的 `identity` symlink 指向共享身份（缺则建）——配置里的 identity/public|private/...
  # 相对路径由它解析到栈根 identity/gateway。目标用相对路径（从 GW_HOME 推导；dev 默认即 ../../../identity/gateway）。
  IDENTITY_LINK_TARGET="$(python3 - "${GW_HOME}" "${GW_IDENTITY}" <<'PY'
import os, sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
)"
  if [[ -L "${IDENTITY_LINK}" ]]; then
    [[ "$(readlink "${IDENTITY_LINK}")" == "${IDENTITY_LINK_TARGET}" ]] || {
      ln -sfn "${IDENTITY_LINK_TARGET}" "${IDENTITY_LINK}"
      note "已修正 identity symlink：${IDENTITY_LINK} → ${IDENTITY_LINK_TARGET}"
    }
  elif [[ -e "${IDENTITY_LINK}" ]]; then
    die "${IDENTITY_LINK} 已存在且不是 symlink —— 它应指向 ${IDENTITY_LINK_TARGET}"
  else
    ln -s "${IDENTITY_LINK_TARGET}" "${IDENTITY_LINK}"
    note "已建 identity symlink：${IDENTITY_LINK} → ${IDENTITY_LINK_TARGET}"
  fi

  # 旧名 dev-ca.* → 统一为 gateway-ca.*（内容不变，锚不变；与发布态同名，便于直接对拷）。
  # 身份已拆到共享目录：老的 state/dev-ca.*（或新目录里的 dev-ca.*）一并搬进共享身份再改名。
  old_crt="" old_key=""
  for base in "${IDENTITY_PUBLIC}" "${IDENTITY_PRIVATE}" "${STATE_DIR}"; do
    [[ -f "${base}/dev-ca.crt.pem" ]] && old_crt="${base}/dev-ca.crt.pem"
    [[ -f "${base}/dev-ca.key.pem" ]] && old_key="${base}/dev-ca.key.pem"
  done
  if [[ -n "${old_crt}" && ! -f "${CA_CRT}" ]]; then
    mv -f "${old_crt}" "${CA_CRT}"
    [[ -n "${old_key}" ]] && mv -f "${old_key}" "${CA_KEY}"
    note "已把 dev-ca.* 改名为 gateway-ca.*（锚内容不变）"
  fi

  # ① CA（只建一次）。它是 agent 的信任锚：**换了它，那批 agent 全部要重装**，
  #    所以已存在时一律复用，绝不顺手重生成。
  if [[ "${USE_CA}" == "1" ]]; then
    if [[ -f "${CA_KEY}" && -f "${CA_CRT}" ]]; then
      note "复用已有 CA：${CA_CRT}"
    else
      openssl req -x509 -newkey rsa:4096 -nodes -sha256 \
        -keyout "${CA_KEY}" -out "${CA_CRT}" -days 3650 \
        -subj "/CN=Wist Gateway Dev CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
      chmod 600 "${CA_KEY}"
      note "新建 CA：${CA_CRT}（这是信任锚，换它 = 所有 agent 重装）"
    fi
  fi

  # ② SAN：新域名 + 传入的旧域名（新旧并存用）+ 本机名（管理台/前端反代还要用）。
  san_parts=()
  for name in "${DOMAINS[@]}"; do
    san_parts+=("DNS:${name}")
  done
  san_parts+=("DNS:localhost" "IP:127.0.0.1")
  SAN="$(printf '%s\n' "${san_parts[@]}" | awk '!seen[$0]++' | paste -sd, -)"

  cat >"${LEAF_EXT}" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${SAN}
EOF

  # ③ 叶证书。私钥是耗材：已存在就复用（轮换应该是刻意的，不该是脚本的副作用）。
  if [[ ! -f "${LEAF_KEY}" ]]; then
    openssl genrsa -out "${LEAF_KEY}" 2048 >/dev/null 2>&1
    chmod 600 "${LEAF_KEY}"
  fi
  CSR="${IDENTITY_PRIVATE}/.admin-tls.csr.pem"
  openssl req -new -key "${LEAF_KEY}" -out "${CSR}" -subj "/CN=${PRIMARY}" >/dev/null 2>&1
  if [[ "${USE_CA}" == "1" ]]; then
    # 序列号文件（.srl）也要落私钥目录（不在公开的 CA 证书目录里）。
    openssl x509 -req -in "${CSR}" -CA "${CA_CRT}" -CAkey "${CA_KEY}" \
      -CAserial "${IDENTITY_PRIVATE}/gateway-ca.crt.srl" -CAcreateserial \
      -out "${LEAF_CRT}" -days 397 -sha256 -extfile "${LEAF_EXT}" >/dev/null 2>&1
    rm -f "${CSR}"
    note "用 CA 签出叶证书：${LEAF_CRT}（SAN: ${SAN}）"
  else
    openssl x509 -req -in "${CSR}" -signkey "${LEAF_KEY}" \
      -out "${LEAF_CRT}" -days 397 -sha256 -extfile "${LEAF_EXT}" >/dev/null 2>&1
    rm -f "${CSR}"
    note "自签叶证书：${LEAF_CRT}（--no-ca：叶证书同时是信任锚）"
  fi
else
  note "DRY_RUN：跳过证书生成/复用"
fi

# trust_bundle_file = 信任锚：有 CA 就是 CA 根，--no-ca 时是叶证书本身；配置只记它的**文件路径**。
if [[ "${USE_CA}" == "1" ]]; then
  ANCHOR_FILE="${CA_CRT}"
else
  ANCHOR_FILE="${LEAF_CRT}"
fi

# ── 改写配置 ──────────────────────────────────────────────────────────────────
# 逐段改行：listen_addr 只改 [server] 段里那个键（[ingest] 也有 listen_addr，不能一条正则
# 打天下）；信任锚只写 `[agent] trust_bundle_file`（指向锚文件），并清掉旧版内联
# `trust_bundle = """…"""`（新配置不认它，留着会让网关以 missing field 起不来）。
# **对外基址不在主配置里**：它在**接口层**（同目录 `wist-gateway-pub.toml`）—— 见下面第二段。
python3 - "${CONFIG}" "${LISTEN_VALUE}" "${PUBLIC_BASE_URL}" "${ANCHOR_FILE}" "${DRY_RUN}" <<'PY'
import os
import re
import sys

path, listen, base_url, anchor_file, dry = sys.argv[1:6]
# 锚在共享身份里（identity/gateway/public），配置里写相对配置目录的路径 —— 经 GW_HOME 的
# identity symlink 解析到栈根共享身份。
anchor_rel = os.path.join("identity", "public", os.path.basename(anchor_file))

with open(path) as handle:
    lines = handle.read().splitlines()

section = ""
out = []
hits = {"listen": 0, "url": 0, "anchor": 0}
index = 0
while index < len(lines):
    line = lines[index]
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped
    if re.match(r"^trust_bundle\s*=", line):
        # 旧版内联锚：连三引号块一起丢弃。
        if '"""' in line and line.count('"""') < 2:
            index += 1
            while index < len(lines) and '"""' not in lines[index]:
                index += 1
        index += 1
        continue
    if section == "[server]":
        if re.match(r"^listen_addr\s*=", line) and listen != "__KEEP__":
            line = f'listen_addr = "{listen}"'
            hits["listen"] += 1
    elif section == "[agent]" and re.match(r"^trust_bundle_file\s*=", line):
        line = f'trust_bundle_file = "{anchor_rel}"'
        hits["anchor"] += 1
    out.append(line)
    index += 1

text = "\n".join(out) + "\n"
if hits["anchor"] == 0:
    text, replaced = re.subn(
        r"(?m)^(\[agent\]\s*)$",
        lambda m: m.group(1) + f'\ntrust_bundle_file = "{anchor_rel}"',
        text,
        count=1,
    )
    if replaced == 1:
        hits["anchor"] = 1

if hits["listen"] > 1 or hits["anchor"] != 1:
    sys.exit(
        "配置改写失败：server.listen_addr %d 处 / agent.trust_bundle_file %d 处 —— "
        "配置形状可能变过，请手工核对" % (hits["listen"], hits["anchor"])
    )

if dry == "1":
    print("DRY_RUN：不改配置。将要写入：")
    print(f'  listen_addr             = "{listen}"')
    print(f'  public_base_url         = "{base_url}"')
    print(f'  agent.trust_bundle_file = "{anchor_rel}"')
else:
    with open(path, "w") as handle:
        handle.write(text)
    print(f"配置已更新：{path}")
    print(f'  listen_addr             = {listen if listen != "__KEEP__" else "(保留原值)"}')
    print(f"  public_base_url         = {base_url}")
    print(f"  trust_bundle_file       = {anchor_rel}")
PY

# 对外基址在**接口层**（同目录 `wist-gateway-pub.toml`，**现场态**），不在主配置里。
# 本脚本就是"换域名"，所以这里**显式覆盖**该键（与 init-gateway-pub.sh 的"只在缺键时种"不同）。
python3 - "${CONFIG}" "${PUBLIC_BASE_URL}" "${DRY_RUN}" <<'PY'
import os
import re
import sys

path, base_url, dry = sys.argv[1:4]
pub_path = os.path.join(os.path.dirname(os.path.abspath(path)), "wist-gateway-pub.toml")
lines = []
if os.path.exists(pub_path):
    with open(pub_path) as handle:
        lines = handle.read().splitlines()


def section_index(name):
    header = f"[{name}]"
    for i, line in enumerate(lines):
        if line.strip() == header:
            return i
    return None


def key_index(si, key):
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for i in range(si + 1, len(lines)):
        s = lines[i].strip()
        if s.startswith("[") and s.endswith("]"):
            return None
        if pattern.match(lines[i]):
            return i
    return None


si = section_index("server")
if si is None:
    if lines and lines[-1].strip() != "":
        lines.append("")
    lines.append("[server]")
    si = len(lines) - 1
ki = key_index(si, "public_base_url")
new_line = f'public_base_url = "{base_url}"'
if ki is None:
    lines.insert(si + 1, new_line)
else:
    lines[ki] = new_line

if dry == "1":
    print(f"DRY_RUN：不改 {pub_path}（将写 public_base_url = {base_url}）")
else:
    with open(pub_path, "w") as handle:
        handle.write("\n".join(lines).rstrip("\n") + "\n")
    print(f"接口层配置已更新：{pub_path}")
    print(f"  public_base_url = {base_url}")
PY

# ── 自检与影响面 ──────────────────────────────────────────────────────────────
GW_BIN="$(cd "${SCRIPT_DIR}/../../wist-gateway/target/debug" && pwd)/wist-gateway"

cat <<EOF

── 自检 ────────────────────────────────────────────────────────────────
证书 SAN（必须含 ${PRIMARY}）：
  openssl x509 -in ${LEAF_CRT} -noout -text | sed -n '/Subject Alternative Name/,+1p'
  （用 -text 不用 -ext：macOS 自带的 LibreSSL 不认 -ext，而 gwlinkd 派生的进程用的就是它）

与 agent 同源校验器（curl 不算数）：用**链式**那条 —— 信任锚单独给（agent 的 trust_bundle 形态），
\`rustls_accepts_gateway_certificate\` 只模拟「锚就是叶证书本身」，对 CA 签的叶会误判 UnknownIssuer。
  WIST_GATEWAY_TLS_CHAIN=${LEAF_CRT} \\
  WIST_GATEWAY_TLS_ANCHOR=${ANCHOR_FILE} \\
  WIST_GATEWAY_TLS_SERVER_NAME=${PRIMARY} \\
    cargo test --offline --lib -- --ignored rustls_accepts_gateway_chain --nocapture

域名与端口：
  getent hosts ${PRIMARY}
  curl -sk -o /dev/null -w '%{http_code}\\n' ${PUBLIC_BASE_URL}/api/v1/agent/install/arm/install.sh

── 起服务 ──────────────────────────────────────────────────────────────
EOF

if [[ "${LISTEN_VALUE}" == "__KEEP__" ]]; then
  cat <<EOF
  监听保持原样，直接用：./dev/svc.sh start gateway
EOF
else
  LISTEN_PORT_NOW="${LISTEN_VALUE##*:}"
  if [[ "${LISTEN_PORT_NOW}" -lt 1024 ]]; then
    cat <<EOF
  ${LISTEN_VALUE} 是特权端口，普通用户绑不了，用 root 起（注意 sudo 下 ~ 是 /var/root，写绝对路径）：
    sudo WIST_GATEWAY_CONFIG=${CONFIG} \\
      ${GW_BIN}

  跑完把属主还回来（否则之后普通用户写不了库/日志，也写不了共享身份里的 .srl）：
    sudo chown -R "\$(whoami)" ${GW_HOME} ${STACK_ROOT}/identity
EOF
  else
    cat <<EOF
  普通端口，直接用：./dev/svc.sh start gateway
EOF
  fi
fi

cat <<EOF

── 别踩这几条 ──────────────────────────────────────────────────────────
  1. **别删 ${LEAF_CRT}**：svc.sh 发现它缺失会按 CN=localhost 重新生成，
     域名就白切了。它每次启动还会把 \`[agent] trust_bundle_file\` 指回锚（有 gateway-ca 时用 CA 根）。
  2. **别对已有配置跑 \`wist-gateway init-config\`**：整份重写，admin token 会变。
EOF

if [[ -n "${URL_PORT}" && "${URL_PORT}" != "3000" ]]; then
  cat <<EOF
  3. 前端 /api 反代目标要跟着改：
       WARP_INSIGHT_WEB_PROXY_TARGET=${PUBLIC_BASE_URL} ./dev/svc.sh start web
EOF
fi

cat <<EOF

── 已装的 agent ────────────────────────────────────────────────────────
EOF

if [[ "${USE_CA}" == "1" ]]; then
  cat <<EOF
  信任锚 = CA 根（${ANCHOR_FILE}）。**这次切换会换掉锚**（从旧的自签证书换成 CA），
  所以本机那个 agentd 必须**重跑一次安装**（install.sh 会重写 endpoint 与 trust_bundle；
  仅重新注册/enroll 不刷新这两样，没用）。

  以后**再**换域名：只要
    · 新域名仍是这张 CA 签的（本脚本会重签）；
    · 旧域名还在 SAN 里、DNS 也还没撤；
  那么老 agent 完全不用动 —— 它们继续用旧名字，新装的用新名字。
EOF
else
  cat <<EOF
  --no-ca：锚就是叶证书本身。**换域名 = 换锚 = 所有 agent 必须重跑安装。**
EOF
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  echo
  echo "（DRY_RUN：以上改动都没有落盘）"
fi
