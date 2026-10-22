#!/usr/bin/env bash
# `scripts/init-knowledge-signing.sh` 的回归测试：公钥指纹必须**算得出来**，而且在守护进程的 PATH 下也算得出来。
#
# 为什么单测它（与 2026-10-23 的升级失败同源）：老实现是
#   `openssl pkey -pubin -in … -outform DER | shasum -a 256`
# 两个坑都只在**非交互环境的 PATH** 里才暴露：
#   · macOS 自带的 `/usr/bin/openssl` 是 LibreSSL，`pkey` **读不了 Ed25519 公钥**（rc=1）——
#     而升级流程由 gwlinkd 派生，PATH 里没有 Homebrew 目录，解析到的正是它；
#   · `shasum` 是 macOS 带的（Perl），精简 Linux（无 perl / alpine）上没有。
# 结果：指纹静默变空 —— 而这串指纹正是「公钥换错了 / 没换成功」唯一能一眼看出的东西
# （网关只会在收包时报 `package_signature_invalid`，看不出是哪把钥匙）。
#
#   dev/tests/knowledge-signing-fingerprint.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
SCRIPT="${STACK_ROOT}/scripts/init-knowledge-signing.sh"
PUBKEY="${STACK_ROOT}/sys/keys/knowledge-signing.pub.pem"
[[ -f "${SCRIPT}" ]] || { echo "找不到 ${SCRIPT}" >&2; exit 1; }
[[ -f "${PUBKEY}" ]] || { echo "找不到 ${PUBKEY}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# 守护进程的 PATH：不含 /opt/homebrew/bin、不含 ~/bin（与 localize-cert-paths.test.sh 同一份）。
MIN_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# 栈树的随包公钥（sys/keys/）就是「交付靠这条」的来源；它签的是发布侧那把私钥。
# 指纹钉死：换钥匙（轮换签名密钥）时必须同步改这里 —— 这正是测试要提示的事。
EXPECTED_FP="502d6b90a96afb0b"

mk_site() { # $1=目录  $2=1 带 sys/keys 公钥 / 0 不带
  local d="$1" with_key="$2"
  mkdir -p "${d}/scripts" "${d}/configs/gateway"
  cp "${SCRIPT}" "${d}/scripts/"
  if [[ "${with_key}" == "1" ]]; then
    mkdir -p "${d}/sys/keys"
    cp "${PUBKEY}" "${d}/sys/keys/"
  fi
  printf '{\n  "public_base_url": "https://gw.example.test"\n}\n' >"${d}/configs/gateway/wist-gateway.value.json"
}

run_site() { # $1=目录  $2...=额外 env（KEY=VAL）
  local d="$1"
  shift
  ( cd "${d}" && env -i HOME="${HOME}" PATH="${MIN_PATH}" "$@" bash ./scripts/init-knowledge-signing.sh configs/gateway 2>&1 )
}

set +e
fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "  [OK]   $1"; else echo "  [FAIL] $1（期望 ${2}，实际 ${3}）"; fail=1; fi; }
has() { case "$2" in *"$1"*) echo "  [OK]   $3" ;; *) echo "  [FAIL] $3：$2"; fail=1 ;; esac; }

echo "== 0) 最小 PATH 下解析到的 openssl（记录用：这正是差异来源）=="
env -i PATH="${MIN_PATH}" sh -c 'command -v openssl; openssl version' | sed 's/^/  /'

echo "== 1) 随包公钥 + 最小 PATH → 指纹算得出来，且与已知值一致 =="
S1="${TMP}/with-key"
mk_site "${S1}" 1
out="$(run_site "${S1}")"; rc=$?
chk "放置公钥 exit 0" "0" "${rc}"
has "已放置验签公钥" "${out}" "公钥已就位"
has "指纹 ${EXPECTED_FP}" "${out}" "指纹非空且等于已知值（LibreSSL 下也算得出）"
chk "公钥落到站点身份" "1" "$([[ -f "${S1}/identity/gateway/public/knowledge-signing.pub.pem" ]] && echo 1 || echo 0)"
has '"knowledge_signing_pubkey": "identity/public/knowledge-signing.pub.pem"' \
  "$(cat "${S1}/configs/gateway/wist-gateway.value.json")" "渲染值已启用验签（网关据此渲染签名键）"

echo "== 2) 再跑一次 → 幂等（不重写文件）=="
before="$(cat "${S1}/identity/gateway/public/knowledge-signing.pub.pem")"
out="$(run_site "${S1}")"; rc=$?
chk "重复跑 exit 0" "0" "${rc}"
has "内容一致，跳过" "${out}" "明确说跳过"
chk "公钥内容未变" "${before}" "$(cat "${S1}/identity/gateway/public/knowledge-signing.pub.pem")"

echo "== 3) 没有公钥来源 → 不启用验签，渲染值不指向公钥 ="
S2="${TMP}/no-key"
mk_site "${S2}" 0
out="$(run_site "${S2}")"; rc=$?
chk "无公钥 exit 0" "0" "${rc}"
has "不启用" "${out}" "说清了验签不启用"
case "$(cat "${S2}/configs/gateway/wist-gateway.value.json")" in
  *"identity/public/knowledge-signing.pub.pem"*)
    echo "  [FAIL] 渲染值不应指向不存在的公钥（网关会拒启）：$(cat "${S2}/configs/gateway/wist-gateway.value.json")"
    fail=1
    ;;
  *) echo "  [OK]   渲染值没指向不存在的公钥" ;;
esac

echo "== 3b) 先启用、再把公钥删掉 → 渲染值必须跟着清空（否则网关拒启）=="
S2b="${TMP}/key-removed"
cp -R "${S1}" "${S2b}"
rm -f "${S2b}/identity/gateway/public/knowledge-signing.pub.pem" "${S2b}/sys/keys/knowledge-signing.pub.pem"
out="$(run_site "${S2b}")"; rc=$?
chk "删公钥后 exit 0" "0" "${rc}"
has "不启用" "${out}" "识别为已无公钥"
has '"knowledge_signing_pubkey": ""' "$(cat "${S2b}/configs/gateway/wist-gateway.value.json")" "渲染值已清空（验签关闭）"

echo "== 4) 指错了文件（不是公钥 PEM）→ 明确失败 =="
S3="${TMP}/bad-key"
mk_site "${S3}" 0
out="$(run_site "${S3}" "KNOWLEDGE_SIGNING_PUBKEY=/etc/hosts")"; rc=$?
chk "非公钥 exit 1" "1" "${rc}"
has "BEGIN PUBLIC KEY" "${out}" "报错点明期望的 PEM 形状"

echo
if [[ "${fail}" == "0" ]]; then
  echo "全部通过"
else
  echo "存在失败项"
  exit 1
fi
