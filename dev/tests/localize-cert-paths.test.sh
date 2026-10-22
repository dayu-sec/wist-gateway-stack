#!/usr/bin/env bash
# 回归测试：localize 的证书备料脚本必须在**守护进程的 PATH** 下工作，而不是交互式 shell 的。
#
# 事故背景（2026-10-23，升级 v0.2.5-alpha 失败并回滚）：
#   `init-gateway.sh` 打完两行 CA note 后**静默退 1**，stderr 空白。根因不是证书逻辑，
#   而是 `openssl x509 -ext subjectAltName` —— 那是 OpenSSL 1.1.1 才有的选项，macOS 自带的
#   `/usr/bin/openssl` 是 LibreSSL，**不认**。手工排查时 `openssl` 解析到 Homebrew 的那份
#   （PATH 里 /opt/homebrew/bin 在前）所以「手工跑得过」；而升级流程由 gwlinkd 派生，
#   它的 PATH 里没有 Homebrew 目录 → 解析到 LibreSSL → 管道在 `set -e` + `pipefail` 下退出，
#   `2>/dev/null` 把原因一起吞掉。
#
# 所以这里**所有 case 都用最小 PATH**（≈ launchd/systemd 给守护进程的那份）跑：
#   /usr/bin:/bin:/usr/sbin:/sbin
# 钉住的行为：
#   1. 新装能建出 CA（CA:TRUE 真的生效）+ 叶（由该 CA 签发），exit 0；
#   2. SAN 覆盖域名 → **不重签**（证书 sha256 不变，幂等）；
#   3. 换域名 / 只是子串 / 通配不覆盖两层 → 重签，且 **CA 不变**（锚稳定）；
#   4. 通配 `*.a.b` 覆盖一层（`x.a.b` 命中，`x.y.a.b` 不命中）；
#   5. 证书文件损坏 / 读不出 SAN → 重签（幂等），**不静默退 1**；
#   6. 包不完整（缺 scripts/lib/tls-san.sh）/ 找不到 openssl → **明确报错**，不是空 stderr。
#
#   dev/tests/localize-cert-paths.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
for f in scripts/init-gateway.sh scripts/init-web-tls.sh scripts/lib/tls-san.sh; do
  [[ -f "${STACK_ROOT}/${f}" ]] || { echo "找不到 ${STACK_ROOT}/${f}" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# 守护进程的 PATH：不含 /opt/homebrew/bin、不含 ~/bin。
MIN_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

mk_stack() { # $1=栈根
  local d="$1"
  mkdir -p "${d}/scripts/lib" "${d}/configs/gateway" "${d}/.wist" "${d}/identity"
  cp "${STACK_ROOT}/scripts/init-gateway.sh" "${d}/scripts/"
  cp "${STACK_ROOT}/scripts/init-web-tls.sh" "${d}/scripts/"
  cp "${STACK_ROOT}/scripts/lib/tls-san.sh" "${d}/scripts/lib/"
}

# 在最小 PATH 下跑一个脚本，输出合并到 stdout。
run_min() { # $1=栈根  $2=域名  $3...=脚本与参数
  local d="$1" domain="$2"
  shift 2
  ( cd "${d}" && env -i HOME="${HOME}" PATH="${MIN_PATH}" WEB_DOMAIN="${domain}" "$@" 2>&1 )
}

run_gw() { # $1=栈根  $2=WEB_DOMAIN
  run_min "$1" "$2" bash ./scripts/init-gateway.sh configs/gateway
}

run_web() { # $1=栈根  $2=域名
  local d="$1"
  shift
  ( cd "${d}" && env -i HOME="${HOME}" PATH="${MIN_PATH}" bash ./scripts/init-web-tls.sh "$@" identity/web 2>&1 )
}

san_text() { # $1=证书
  env -i PATH="${MIN_PATH}" openssl x509 -in "$1" -noout -text
}

set +e
fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "  [OK]   $1"; else echo "  [FAIL] $1（期望 ${2}，实际 ${3}）"; fail=1; fi; }
has() { case "$2" in *"$1"*) echo "  [OK]   $3" ;; *) echo "  [FAIL] $3：$2"; fail=1 ;; esac; }
hasnt() { case "$2" in *"$1"*) echo "  [FAIL] $3：$2"; fail=1 ;; *) echo "  [OK]   $3" ;; esac; }

echo "== 0) 最小 PATH 下解析到的 openssl（记录用，差异就是事故来源）=="
env -i PATH="${MIN_PATH}" sh -c 'command -v openssl; openssl version' | sed 's/^/  /'

echo "== 1) 新装：建 CA + 叶，退出码 0 =="
S="${TMP}/fresh"
mk_stack "${S}"
out="$(run_gw "${S}" "gw.example.test")"; rc=$?
chk "新装 exit 0" "0" "${rc}"
CA="${S}/identity/gateway/public/gateway-ca.crt.pem"
CRT="${S}/identity/gateway/public/admin-tls.crt.pem"
has "已建网关 CA" "${out}" "建出了网关 CA"
has "已用 CA 签发网关叶证书" "${out}" "签出了叶证书"
has "CA:TRUE" "$(san_text "${CA}")" "CA 证书带 basicConstraints CA:TRUE（-addext 真的生效）"
env -i PATH="${MIN_PATH}" openssl verify -CAfile "${CA}" "${CRT}" >/dev/null 2>&1
chk "叶由该 CA 签发" "0" "$?"
chk "新装 value.json 已生成" "1" "$([[ -f "${S}/configs/gateway/wist-gateway.value.json" ]] && echo 1 || echo 0)"
chk "新装 admin_token 已生成" "1" "$([[ -s "${S}/.wist/sec-value.yml" ]] && echo 1 || echo 0)"

echo "== 2) SAN 覆盖域名 → 不重签（幂等）=="
before="$(sha "${CRT}")"
out="$(run_gw "${S}" "gw.example.test")"; rc=$?
chk "同域名 exit 0" "0" "${rc}"
has "跳过" "${out}" "明确说了跳过"
chk "证书未被重签（sha256 不变）" "${before}" "$(sha "${CRT}")"

echo "== 3) 换域名 → 重签，且 CA 不变（锚稳定）=="
ca_before="$(sha "${CA}")"
out="$(run_gw "${S}" "gw2.example.test")"; rc=$?
chk "换域名 exit 0" "0" "${rc}"
chk "证书已重签" "1" "$([[ "${before}" != "$(sha "${CRT}")" ]] && echo 1 || echo 0)"
has "DNS:gw2.example.test" "$(san_text "${CRT}")" "新 SAN 含新域名"
has "DNS:localhost" "$(san_text "${CRT}")" "新 SAN 保留 localhost"
has "IP Address:127.0.0.1" "$(san_text "${CRT}")" "新 SAN 保留 127.0.0.1"
chk "CA 未被重生成" "${ca_before}" "$(sha "${CA}")"

echo "== 4) 子串不算覆盖：SAN 为 gw.example.test.evil.net 时必须重签 =="
S2="${TMP}/substr"
mk_stack "${S2}"
run_gw "${S2}" "gw.example.test.evil.net" >/dev/null 2>&1
CRT2="${S2}/identity/gateway/public/admin-tls.crt.pem"
before="$(sha "${CRT2}")"
out="$(run_gw "${S2}" "gw.example.test")"; rc=$?
chk "子串场景 exit 0" "0" "${rc}"
has "重签" "${out}" "判为不覆盖并重签"
chk "证书已重签" "1" "$([[ "${before}" != "$(sha "${CRT2}")" ]] && echo 1 || echo 0)"
has "DNS:gw.example.test" "$(san_text "${CRT2}")" "新 SAN 精确等于目标域名"

echo "== 5) 通配只覆盖一层：*.example.test 命中 gw.example.test，不命中 a.b.example.test =="
S3="${TMP}/wildcard"
mk_stack "${S3}"
run_gw "${S3}" "*.example.test" >/dev/null 2>&1
CRT3="${S3}/identity/gateway/public/admin-tls.crt.pem"
has "DNS:*.example.test" "$(san_text "${CRT3}")" "已造出通配叶证书"
before="$(sha "${CRT3}")"
out="$(run_gw "${S3}" "gw.example.test")"; rc=$?
chk "通配覆盖一层 exit 0" "0" "${rc}"
has "跳过" "${out}" "通配覆盖一层 → 跳过"
chk "证书未被重签" "${before}" "$(sha "${CRT3}")"
out="$(run_gw "${S3}" "a.b.example.test")"; rc=$?
chk "跨两层 exit 0" "0" "${rc}"
chk "跨两层必须重签" "1" "$([[ "${before}" != "$(sha "${CRT3}")" ]] && echo 1 || echo 0)"

echo "== 6) 证书损坏 → 重签而不是静默退 1 =="
S4="${TMP}/broken"
mk_stack "${S4}"
run_gw "${S4}" "gw.example.test" >/dev/null 2>&1
printf 'not a certificate\n' >"${S4}/identity/gateway/public/admin-tls.crt.pem"
out="$(run_gw "${S4}" "gw.example.test")"; rc=$?
chk "损坏证书 exit 0" "0" "${rc}"
has "重签" "${out}" "识别为不可用并重签"
env -i PATH="${MIN_PATH}" openssl x509 -in "${S4}/identity/gateway/public/admin-tls.crt.pem" -noout -text >/dev/null 2>&1
chk "重签后的证书可解析" "0" "$?"

echo "== 7) 包不完整（缺 lib）→ 明确报错 =="
S5="${TMP}/nolib"
mk_stack "${S5}"
rm -f "${S5}/scripts/lib/tls-san.sh"
out="$(run_gw "${S5}" "gw.example.test")"; rc=$?
chk "缺 lib exit 1" "1" "${rc}"
has "安装包不完整" "${out}" "报错点明包不完整"
hasnt "复用已有 CA" "${out}" "不会先干一半活再死"

echo "== 8) 找不到 openssl → 明确报错 =="
S6="${TMP}/noopenssl"
mk_stack "${S6}"
# 造一个「除 openssl 外都有」的 PATH：直接从 /usr/bin、/bin 链过去（注意 /usr/bin 里
# 目录/特殊文件不多，链不过去的忽略）。不能直接空 PATH —— 那样连 bash/mkdir 都找不到，
# 报出来的错就不是脚本自己的判定了。
BIN="${TMP}/bin-nossl"
mkdir -p "${BIN}"
for d in /usr/bin /bin; do
  for f in "${d}"/*; do
    if [[ "${f##*/}" == "openssl" ]]; then
      continue
    fi
    ln -sf "${f}" "${BIN}/" 2>/dev/null || true
  done
done
out="$( cd "${S6}" && env -i HOME="${HOME}" PATH="${BIN}" WEB_DOMAIN="gw.example.test" "$(command -v bash)" ./scripts/init-gateway.sh configs/gateway 2>&1 )"; rc=$?
chk "无 openssl exit 1" "1" "${rc}"
has "openssl" "${out}" "报错提到 openssl"

echo "== 9) web 证书脚本：与网关同口径（幂等 / 换域名重签 / 子串重签）=="
S7="${TMP}/web"
mk_stack "${S7}"
out="$(run_web "${S7}" "web.example.test")"; rc=$?
chk "web 首次 exit 0" "0" "${rc}"
WCRT="${S7}/identity/web/public/web-tls.crt.pem"
has "已用 web CA 签发叶证书" "${out}" "签出 web 叶证书"
before="$(sha "${WCRT}")"
out="$(run_web "${S7}" "web.example.test")"; rc=$?
chk "web 幂等 exit 0" "0" "${rc}"
has "跳过" "${out}" "web 叶证书跳过重签"
chk "web 证书未被重签" "${before}" "$(sha "${WCRT}")"
out="$(run_web "${S7}" "other.example.test")"; rc=$?
chk "web 换域名 exit 0" "0" "${rc}"
chk "web 证书已重签" "1" "$([[ "${before}" != "$(sha "${WCRT}")" ]] && echo 1 || echo 0)"
has "DNS:other.example.test" "$(san_text "${WCRT}")" "web 新 SAN 含新域名"

echo
if [[ "${fail}" == "0" ]]; then
  echo "全部通过"
else
  echo "存在失败项"
  exit 1
fi
