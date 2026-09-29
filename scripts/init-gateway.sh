#!/usr/bin/env bash
# 生成/复用网关运行所需的 **CA / 密钥 / 证书 / 渲染值**（纯宿主 openssl，不依赖 wist-gateway 二进制或镜像）。
#
# 身份模型（重要）：
#   本脚本建立一张**网关 CA**，网关的**叶证书由它签发**，agent 的信任锚 = **CA 根**
#   （configs/gateway/wist-gateway.toml 的 agent.trust_bundle_file → state/gateway-ca.crt.pem）。
#   于是：换域名 / 续期 / 换 SAN 只**重签叶证书**，锚不变、**agent 无感**。
#   CA 私钥不可再生 —— 丢了 = 换锚 = 全队 agent 重装，务必备份。
#
# 幂等：CA 一旦建立绝不重生成；叶证书仅在「缺失 / 与当前 CA 不对应 / SAN 不含域名」时重签。
#
# 用法：
#   scripts/init-gateway.sh [目标目录]        # 默认 configs/gateway
#
# 生成物：
#   <dir>/state/gateway-ca.key.pem / gateway-ca.crt.pem     # 网关 CA（锚；私钥务必备份）
#   <dir>/state/admin-tls.key.pem / admin-tls.crt.pem       # 网关叶证书（CA 签；可轮换）
#   <dir>/state/install-script-signing-ed25519.pkcs8.pem    # 安装脚本签名私钥（Ed25519 PKCS#8；可重生）
#   <dir>/wist-gateway.value.json                           # 渲染模板用的值（token / url / package）
#
# 注意：**不生成** wist-gateway.toml —— 它由 localize 阶段流程从
#   sys/configs/gateway/wist-gateway.toml.tpl 渲染（gx.tpl）。
#
# 可覆盖 env：
#   WEB_DOMAIN          对外域名：证书 SAN 与 public_base_url 的 host（缺省时从已有 value.json 推断）
#   AGENT_PACKAGE_FILE  容器内可见的 agentd 安装包文件名（缺省：目录里的 wist-agentd-*.tar.gz）
#   CERT_DAYS           叶证书有效期天数（默认 397）
#   CA_DAYS             CA 有效期天数（默认 3650）
#   GATEWAY_CA_CRT / GATEWAY_CA_KEY   复用**外部 CA**（两者都提供才生效；用于既有 CA 或 KMS/HSM 导出的 CA）
set -euo pipefail

DIR="${1:-configs/gateway}"
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"
STATE="$DIR/state"
mkdir -p "$STATE"

CA_KEY="$STATE/gateway-ca.key.pem"
CA_CRT="$STATE/gateway-ca.crt.pem"
TLS_CRT="$STATE/admin-tls.crt.pem"
TLS_KEY="$STATE/admin-tls.key.pem"
SIGNING_KEY="$STATE/install-script-signing-ed25519.pkcs8.pem"
VALUE_JSON="$DIR/wist-gateway.value.json"
CERT_DAYS="${CERT_DAYS:-397}"
CA_DAYS="${CA_DAYS:-3650}"

command -v openssl >/dev/null 2>&1 || { echo "缺少 openssl，无法生成密钥/证书" >&2; exit 1; }

note() { echo "  $*"; }

# 域名：env 优先；否则从已有 value.json 的 public_base_url 里取 host
domain="${WEB_DOMAIN:-}"
if [[ -z "$domain" && -f "$VALUE_JSON" ]]; then
  domain="$(sed -n 's/.*"public_base_url"[[:space:]]*:[[:space:]]*"https\{0,1\}:\/\/\([^"\/]*\).*/\1/p' "$VALUE_JSON" | head -n1)"
  domain="${domain%%:*}" # 去掉可能的端口
fi

# ① 网关 CA（信任锚；只建一次，绝不重生成）
if [[ -n "${GATEWAY_CA_CRT:-}" && -n "${GATEWAY_CA_KEY:-}" ]]; then
  # 导入外部 CA 到 state/（配置固定引用 state/gateway-ca.crt.pem，故复制而非外链）
  cp -f "$GATEWAY_CA_CRT" "$CA_CRT"
  cp -f "$GATEWAY_CA_KEY" "$CA_KEY"
  chmod 600 "$CA_KEY"
  note "已导入外部 CA → ${CA_CRT}"
elif [[ -f "$CA_KEY" && -f "$CA_CRT" ]]; then
  note "复用已有 CA：${CA_CRT}"
else
  openssl req -x509 -newkey rsa:4096 -nodes -sha256 \
    -keyout "$CA_KEY" -out "$CA_CRT" -days "$CA_DAYS" \
    -subj "/CN=Wist Gateway CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
  chmod 600 "$CA_KEY"
  note "已建网关 CA（信任锚，私钥务必备份）：${CA_CRT}"
fi

# ② 网关叶证书（由 CA 签发；缺 / 与当前 CA 不对应 / SAN 缺域名 → 重签）
if [[ -z "$domain" ]]; then
  echo "需要 WEB_DOMAIN 才能生成/重签 TLS 证书（未提供，且无法从 value.json 推断）" >&2
  exit 1
fi
leaf_ok=0
if [[ -f "$TLS_CRT" && -f "$TLS_KEY" ]] \
  && openssl verify -CAfile "$CA_CRT" "$TLS_CRT" >/dev/null 2>&1 \
  && openssl x509 -in "$TLS_CRT" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:${domain}"; then
  leaf_ok=1
fi
if [[ "$leaf_ok" == 1 ]]; then
  note "叶证书已由当前 CA 签发且含域名，跳过：${TLS_CRT}"
else
  [[ -f "$TLS_CRT" ]] && note "已有叶证书与当前 CA 不对应或缺域名，重签"
  if [[ ! -f "$TLS_KEY" ]]; then
    openssl genrsa -out "$TLS_KEY" 2048 >/dev/null 2>&1
    chmod 600 "$TLS_KEY"
  fi
  ext="$STATE/.leaf.ext"
  csr="$STATE/.leaf.csr"
  cat >"$ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${domain},DNS:localhost,IP:127.0.0.1
EOF
  openssl req -new -key "$TLS_KEY" -out "$csr" -subj "/CN=${domain}" >/dev/null 2>&1
  openssl x509 -req -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$TLS_CRT" -days "$CERT_DAYS" -sha256 -extfile "$ext" >/dev/null 2>&1
  rm -f "$csr" "$ext"
  note "已用 CA 签发网关叶证书：${TLS_CRT}（SAN: ${domain},localhost,127.0.0.1）"
fi

# ③ 安装脚本签名私钥（Ed25519 PKCS#8）。模板 `install_script_signing_private_key_file` 引用它，
#    网关启动要求它**存在**（缺失即拒绝启动）；缺则生成（幂等）。可重生：只影响之后签发的安装脚本。
if [[ -f "$SIGNING_KEY" ]]; then
  note "签名私钥已存在，跳过：${SIGNING_KEY}"
else
  openssl genpkey -algorithm ED25519 -out "$SIGNING_KEY" >/dev/null 2>&1
  chmod 600 "$SIGNING_KEY"
  note "已生成安装脚本签名私钥（Ed25519 PKCS#8）：${SIGNING_KEY}"
fi

# ④ 渲染值文件（token / url / package）。**只在缺失时写** —— token 一旦生成必须持久。
if [[ -f "$VALUE_JSON" ]]; then
  note "值文件已存在，跳过：${VALUE_JSON}"
else
  pkg="${AGENT_PACKAGE_FILE:-}"
  if [[ -z "$pkg" ]]; then
    pkg="$(cd "$DIR" && ls wist-agentd-*.tar.gz 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$pkg" ]]; then
    pkg="wist-agentd.tar.gz"
    note "警告：目录里没有 wist-agentd-*.tar.gz，package_file 先写 ${pkg}，请把安装包放到 ${DIR}/"
  fi
  token="$(openssl rand -hex 24)"
  cat >"$VALUE_JSON" <<EOF
{
  "public_base_url": "https://${domain}",
  "admin_api_token": "${token}",
  "package_file": "${pkg}"
}
EOF
  chmod 600 "$VALUE_JSON"
  note "已生成值文件：${VALUE_JSON}（admin token 已随机生成）"
fi

echo "init-gateway 完成：${DIR}（锚 = ${CA_CRT}）"
