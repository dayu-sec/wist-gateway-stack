#!/usr/bin/env bash
# 生成/复用**前端站点**（web 容器）的 TLS 自签证书。
#
# 与网关那张证书**分开**：web 只拿自己这张，网关私钥（它同时是 agent 的信任锚）不进 web 容器，
# 泄漏面单独控制。web 容器把本目录挂到 /certs，nginx 在 443 上用它终止 TLS。
#
# 用法：
#   scripts/init-web-tls.sh <域名> [输出目录]
#     scripts/init-web-tls.sh c-dev01.test.gw.jingang.cloud
#
# 生成（幂等，已存在则跳过）：
#   <输出目录>/web-tls.crt.pem / web-tls.key.pem     默认 输出目录 = configs/web/tls
#
# 可覆盖 env：
#   CERT_DAYS  证书有效期天数（默认 365）
#
# 说明：自签叶证书（basicConstraints CA:FALSE），浏览器会提示“不受信”；要免提示需换成真实 CA
#       签发的证书（把同名 crt/key 放进来即可覆盖）。证书一换，浏览器需重新信任。
set -euo pipefail

DOMAIN="${1:?用法: $0 <域名> [输出目录]}"
OUT_DIR="${2:-configs/web/tls}"
CERT_DAYS="${CERT_DAYS:-365}"

mkdir -p "${OUT_DIR}"
CRT="${OUT_DIR}/web-tls.crt.pem"
KEY="${OUT_DIR}/web-tls.key.pem"

if [[ -f "${CRT}" && -f "${KEY}" ]]; then
  echo "web TLS 证书已存在，跳过：${CRT}"
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "缺少 openssl，无法生成 TLS 证书" >&2
  exit 1
fi

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${KEY}" -out "${CRT}" \
  -days "${CERT_DAYS}" -subj "/CN=${DOMAIN}" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "subjectAltName=DNS:${DOMAIN},DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1

echo "已生成 web TLS 证书/私钥：${CRT} / ${KEY}"
