#!/usr/bin/env bash
# TLS 证书 SAN 读取 / 「SAN 是否覆盖域名」判定 —— **脚本侧唯一实现**。
#
# 为什么单独成一个文件（两个理由，都是踩过的坑）：
#
#  1. **实现差异**：macOS 自带的 `/usr/bin/openssl` 是 LibreSSL，而
#     `openssl x509 -ext subjectAltName` 是 OpenSSL 1.1.1 才有的选项，LibreSSL 不认。
#     交互式 shell 里 `openssl` 往往解析到 Homebrew 的（/opt/homebrew/bin 在前），
#     但**升级流程由 gwlinkd 派生**，它的 PATH 里没有 Homebrew 目录 —— 于是同一个脚本
#     「手工跑得过、升级时静默退 1」。2026-10-23 升级 v0.2.5-alpha 失败就是这一条：
#     `san_entries="$(... -ext ... )"` 在 `set -e` + `pipefail` 下直接退出，stderr 空白。
#     所以这里**一律用 `-text` 解析**，两种实现都支持。
#
#  2. **口径统一**：「SAN 是否覆盖域名」必须与 `tools/stackcheck/src/checks.rs::san_covers`
#     完全同口径（精确相等；`*.a.b` 只覆盖**一层**）。脚本各自抄一份出过一次死锁
#     （闸门判 FAIL、localize 却不重签），故脚本侧只留这一处，改这里时同步改 Rust 那边。
#
# 用法：
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/tls-san.sh"
#   wist_san_covers_domain <证书> <域名>    # 0=覆盖  1=不覆盖  2=读不出
#   wist_san_dns <证书>                     # 一行一个 DNS 名
#   wist_openssl_desc                       # 当前解析到的 openssl（告警里带上，便于反查）
#
# ⚠ `set -e` 下不要把返回 1/2 的调用写成裸语句，用 `if` / `||` 接住。

# 证书里的 DNS 型 SAN，一行一个。读不出（文件不是证书 / openssl 不可用）时返回非 0。
#
# 解析的是 `x509 -text` 而不是 `-ext`：LibreSSL 3.3.6（macOS 自带）只支持前者。
# 段截取用「Subject Alternative Name」到下一个 X509v3/签名段——OpenSSL 3.x 与 LibreSSL
# 都把 SAN 条目排在同一行，但长条目/旧版本会换行，所以先 `tr ','` 拆开再逐行取 DNS。
wist_san_dns() { # $1=证书路径
  local text
  # 先把 openssl 的成败**单独**判掉：不要指望调用方开了 `pipefail`，否则「读不出」
  # 会被最后一段 sed 的 0 掩盖成「没有 SAN」——那正是静默放过的入口。
  if ! text="$(openssl x509 -in "$1" -noout -text 2>/dev/null)"; then
    return 1
  fi
  printf '%s\n' "${text}" | awk '
    /Subject Alternative Name/ { inseg = 1; next }
    inseg && /^[[:space:]]*(X509v3|Signature Algorithm|Subject:|Issuer:|Authority Key|Subject Key)/ { inseg = 0 }
    inseg { print }
  ' | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS:[[:space:]]*//p' | sed 's/[[:space:]]*$//'
}

# 「SAN 条目是否覆盖域名」：**精确**相等，或 `*.a.b` 只覆盖一层
# （`x.a.b` 命中，`x.y.a.b` 不命中），大小写不敏感 —— 与 Rust `san_covers` 同口径。
#
# 不能用 `grep "DNS:${domain}"`：`.` 在正则里是通配符，而且是**子串**匹配 ——
# 证书 SAN 为 `gw.example.com.evil.net` 时也会判「已含」，于是永远不会重签。
wist_san_covers() { # $1=SAN 条目  $2=域名
  local san target suffix label
  san="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  target="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  san="${san%.}"
  target="${target%.}"
  if [[ "$san" == "$target" ]]; then
    return 0
  fi
  if [[ "$san" != '*.'* ]]; then
    return 1
  fi
  suffix="${san#\*.}"
  case "$target" in
    *".${suffix}") ;;
    *) return 1 ;;
  esac
  label="${target%".${suffix}"}"
  if [[ -z "$label" || "$label" == *.* ]]; then
    return 1
  fi
  return 0
}

# 证书的 SAN 是否覆盖域名。0=覆盖  1=不覆盖  2=**读不出**（调用方不能当「覆盖」，
# 也不能静默退出：按「不覆盖」重签并告警）。
wist_san_covers_domain() { # $1=证书路径  $2=域名
  local entries san
  if ! entries="$(wist_san_dns "$1")"; then
    return 2
  fi
  while IFS= read -r san; do
    if [[ -z "$san" ]]; then
      continue
    fi
    if wist_san_covers "$san" "$2"; then
      return 0
    fi
  done <<<"${entries}"
  return 1
}

# 当前 PATH 解析到的 openssl 是哪一份（失败现场最难反查的就是这个差异）。
wist_openssl_desc() {
  local bin version
  bin="$(command -v openssl 2>/dev/null || true)"
  version="$(openssl version 2>/dev/null || echo '无法执行')"
  printf '%s（%s）' "${bin:-找不到 openssl}" "${version}"
}
