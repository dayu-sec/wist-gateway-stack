#!/usr/bin/env bash
# 生成/复用**前端站点**（web 容器）的 TLS 证书 —— **两级**：一张 web CA + 由它签的叶。
#
# 与网关那张证书**分开**：web 只拿自己这套，网关私钥（它同时是 agent 的信任锚）不进 web 容器，
# 泄漏面单独控制。web 容器把本目录挂到 /certs，nginx 在 443 上用它终止 TLS。
#
# 为什么要两级（而不是自签叶）：
#   自签叶（basicConstraints CA:FALSE）**不能**被当作 CA 信任 —— 浏览器只给"按站点例外"，
#   而例外是按证书绑定的，**证书一换就失效**（换域名 / 到期重签 / 重建 configs 都要重新放行）。
#   改成 CA + 叶后：把 **CA 导入一次**，之后凡是它签的叶浏览器自动接受，换叶零动作。
#
# 用法：
#   scripts/init-web-tls.sh <域名> [身份目录]
#     scripts/init-web-tls.sh c-dev01.test.gw.jingang.cloud
#
# 生成（幂等）——身份目录下分公开/私密两半（公开进 contract、私密进 backup）：
#   <身份>/public/web-ca.crt.pem     # CA 证书（信任锚）：**只建一次，绝不重生成**
#   <身份>/public/web-tls.crt.pem    # 叶：由 CA 签；缺 / 与当前 CA 不对应 / SAN 缺域名 → 重签
#   <身份>/private/web-ca.key.pem    # CA 私钥（0600 务必备份）；<身份>/private/web-ca.crt.srl 序列号
#
# 浏览器免提示（这一步永远需要人做一次，脚本只把材料递到手上）：
#   把 `web-ca.crt.pem` 导入信任库。Firefox：设置 → 隐私与安全 → 证书 → 查看证书… →
#   证书颁发机构 → 导入 → 勾「信任此 CA 来标识网站」。
#   ⚠️ Firefox **默认不读** macOS 钥匙串：只把 CA 放进钥匙串（Chrome/Safari 会认）而不开
#      `security.enterprise_roots.enabled`，Firefox 照样报警。
#
# 可覆盖 env：
#   CERT_DAYS            叶有效期天数（默认 365）
#   CA_DAYS              CA 有效期天数（默认 3650）
#   WEB_CA_CRT/WEB_CA_KEY 复用**外部 CA**（两者都提供才生效；用于既有 CA 或 KMS/HSM 导出的 CA）
set -euo pipefail

DOMAIN="${1:?用法: $0 <域名> [身份目录]}"
OUT_DIR="${2:-identity/web}"
CERT_DAYS="${CERT_DAYS:-365}"
CA_DAYS="${CA_DAYS:-3650}"

PUB="${OUT_DIR}/public"
PRIV="${OUT_DIR}/private"
mkdir -p "${PUB}" "${PRIV}"
CA_CRT="${PUB}/web-ca.crt.pem"
CA_KEY="${PRIV}/web-ca.key.pem"
CRT="${PUB}/web-tls.crt.pem"
KEY="${PRIV}/web-tls.key.pem"
SRL="${PRIV}/web-ca.crt.srl"

note() { echo "  $*"; }

if ! command -v openssl >/dev/null 2>&1; then
  echo "缺少 openssl，无法生成 TLS 证书" >&2
  exit 1
fi

# ① web CA（信任锚；只建一次，绝不重生成 —— 重生成 = 换锚 = 每台浏览器都要重新导入）
if [[ -n "${WEB_CA_CRT:-}" && -n "${WEB_CA_KEY:-}" ]]; then
  # 导入外部 CA（nginx 固定引用 public/private 下的文件名，故复制而非外链）
  cp -f "$WEB_CA_CRT" "$CA_CRT"
  cp -f "$WEB_CA_KEY" "$CA_KEY"
  chmod 600 "$CA_KEY"
  note "已导入外部 web CA → ${CA_CRT}"
elif [[ -f "$CA_KEY" && -f "$CA_CRT" ]]; then
  note "复用已有 web CA：${CA_CRT}"
else
  openssl req -x509 -newkey rsa:4096 -nodes -sha256 \
    -keyout "$CA_KEY" -out "$CA_CRT" -days "$CA_DAYS" \
    -subj "/CN=Wist Gateway Web CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
  chmod 600 "$CA_KEY"
  note "已建 web CA（信任锚，私钥务必备份）：${CA_CRT}"
fi

# ② 叶证书（由 CA 签发；缺 / 与当前 CA 不对应 / SAN 缺域名 → 重签）
#    SAN 固定带上 localhost 与 127.0.0.1：`https://localhost:8443` 是现场最常用的入口。
leaf_ok=0
if [[ -f "$CRT" && -f "$KEY" ]] \
  && openssl verify -CAfile "$CA_CRT" "$CRT" >/dev/null 2>&1 \
  && openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:${DOMAIN}"; then
  leaf_ok=1
fi
if [[ "$leaf_ok" == 1 ]]; then
  note "叶证书已由当前 CA 签发且含域名 ${DOMAIN}，跳过：${CRT}"
else
  if [[ -f "$CRT" ]]; then
    note "已有叶证书与当前 CA 不对应或缺域名 ${DOMAIN}，重签"
  fi
  if [[ ! -f "$KEY" ]]; then
    openssl genrsa -out "$KEY" 2048 >/dev/null 2>&1
    chmod 600 "$KEY"
  fi
  ext="${PRIV}/.leaf.ext"
  csr="${PRIV}/.leaf.csr"
  cat >"$ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${DOMAIN},DNS:localhost,IP:127.0.0.1
EOF
  openssl req -new -key "$KEY" -out "$csr" -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  openssl x509 -req -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAserial "$SRL" -CAcreateserial \
    -out "$CRT" -days "$CERT_DAYS" -sha256 -extfile "$ext" >/dev/null 2>&1
  rm -f "$csr" "$ext"
  note "已用 web CA 签发叶证书：${CRT}（SAN: ${DOMAIN},localhost,127.0.0.1）"
fi

# ③ 把"要让浏览器免提示该导哪一份"递到手上（每轮都打：没导过的机器就是靠这几行做的）
fp="$(openssl x509 -in "$CA_CRT" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')"
echo
echo "浏览器免提示：导入这份 CA（只需一次，之后换叶零动作） ——"
echo "  ${CA_CRT}"
echo "  sha256 ${fp}"
echo "  Firefox：设置 → 隐私与安全 → 证书 → 查看证书… → 证书颁发机构 → 导入，勾「信任此 CA 来标识网站」"
