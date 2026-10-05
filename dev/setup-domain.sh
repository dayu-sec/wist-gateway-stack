#!/usr/bin/env bash
# 把网关切到某个域名（域名 = 网关的身份）。
#
# 做四件事：
#   1. 建/复用一张小 CA（state/gateway-ca.*.pem）—— 它成为 agent 的信任锚；
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

GW_HOME="${WIST_GATEWAY_HOME:-${SCRIPT_DIR}/configs/gateway}"
CONFIG="${GW_HOME}/wist-gateway.toml"
STATE_DIR="${GW_HOME}/state"
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
mkdir -p "${STATE_DIR}"

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
CA_KEY="${STATE_DIR}/gateway-ca.key.pem"
CA_CRT="${STATE_DIR}/gateway-ca.crt.pem"
LEAF_KEY="${STATE_DIR}/admin-tls.key.pem"
LEAF_CRT="${STATE_DIR}/admin-tls.crt.pem"
LEAF_EXT="${STATE_DIR}/admin-tls.ext"

note() {
  echo "  $*"
}

if [[ "${DRY_RUN}" != "1" ]]; then
  # 旧名 dev-ca.* → 统一为 gateway-ca.*（内容不变，锚不变；与发布态同名，便于直接对拷）。
  if [[ -f "${STATE_DIR}/dev-ca.crt.pem" && ! -f "${CA_CRT}" ]]; then
    mv -f "${STATE_DIR}/dev-ca.crt.pem" "${CA_CRT}"
    [[ -f "${STATE_DIR}/dev-ca.key.pem" ]] && mv -f "${STATE_DIR}/dev-ca.key.pem" "${CA_KEY}"
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
  CSR="${STATE_DIR}/admin-tls.csr.pem"
  openssl req -new -key "${LEAF_KEY}" -out "${CSR}" -subj "/CN=${PRIMARY}" >/dev/null 2>&1
  if [[ "${USE_CA}" == "1" ]]; then
    openssl x509 -req -in "${CSR}" -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
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
# 逐段改行：listen_addr / public_base_url 只改 [server] 段里那两个键（[ingest] 也有
# listen_addr，不能一条正则打天下）；信任锚只写 `[agent] trust_bundle_file`（指向锚文件），
# 并清掉旧版内联 `trust_bundle = """…"""`（新配置不认它，留着会让网关以 missing field 起不来）。
python3 - "${CONFIG}" "${LISTEN_VALUE}" "${PUBLIC_BASE_URL}" "${ANCHOR_FILE}" "${DRY_RUN}" <<'PY'
import os
import re
import sys

path, listen, base_url, anchor_file, dry = sys.argv[1:6]
anchor_rel = os.path.join("state", os.path.basename(anchor_file))

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
        elif re.match(r"^public_base_url\s*=", line):
            line = f'public_base_url = "{base_url}"'
            hits["url"] += 1
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

if hits["url"] != 1 or hits["listen"] > 1 or hits["anchor"] != 1:
    sys.exit(
        "配置改写失败：server.listen_addr %d 处 / server.public_base_url %d 处 / "
        "agent.trust_bundle_file %d 处 —— 配置形状可能变过，请手工核对"
        % (hits["listen"], hits["url"], hits["anchor"])
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

# ── 自检与影响面 ──────────────────────────────────────────────────────────────
GW_BIN="$(cd "${SCRIPT_DIR}/../../wist-gateway/target/debug" && pwd)/wist-gateway"

cat <<EOF

── 自检 ────────────────────────────────────────────────────────────────
证书 SAN（必须含 ${PRIMARY}）：
  openssl x509 -in ${LEAF_CRT} -noout -ext subjectAltName

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

  跑完把属主还回来（否则之后普通用户写不了库）：
    sudo chown -R "\$(whoami)" ${GW_HOME}
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
     域名就白切了。它每次启动还会把 `[agent] trust_bundle_file` 指回锚（有 gateway-ca 时用 CA 根）。
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
