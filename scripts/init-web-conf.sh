#!/usr/bin/env bash
# 生成前端站点模板的**渲染值** configs/web/nginx.value.json（localize 里 gx.tpl 的输入）。
#
# 为什么必须落在脚本里，而不是在 operators.gxl 里 printf 直接写：
#   GXL 字符串字面量**不做转义还原** —— `\"` 会原样留下反斜杠（orion_parse::define::take_string
#   用 winnow 的 take_escaped，取的是原始切片，`assert_eq!(take_escaped(..).parse_peek(r#"12\"34"#), Ok(.., r#"12\"34"#)))`）。
#   命令最终由 `/bin/sh -c` 执行，而 Debian/Ubuntu 的 /bin/sh 是 **dash**：dash 的 printf 不认 `\"`，
#   把反斜杠一起写进文件 → 非法 JSON → gx.tpl 报 `parse json data file`，localize 中断。
#   同一行在 macOS 上（sh = bash，printf 会把 `\"` 吃成 `"`）却是对的 —— 典型「本机好好的、上云就炸」。
#   写成脚本文件就没有这一层：引号是文件里的普通字符，printf 的格式串里不再有反斜杠。
#
# 用法：
#   scripts/init-web-conf.sh <域名> [输出目录]
#     scripts/init-web-conf.sh c-dev01.test.gw.jingang.cloud
#
# 产出（均幂等）：
#   <输出目录>/nginx.value.json   站点配置模板的渲染值（web_domain）
#   <输出目录>/htpasswd           入口 basic auth 的 apr1 摘要（口令来自密钥文件的 web_entry_password）
#
# 口令**只存密钥文件**（sys-prj.yml: secrets.file 的 `web_entry_password`）：
# 这里只算摘要，不回显、不进 .env、不进渲染值。换口令 = 改密钥 + 重跑 localize + 重启 web。
#
# 幂等：内容与当前一致就跳过（不碰 mtime）。域名只允许主机名字符 —— 既是校验，也保证它进 JSON
# 不需要任何转义（空白 / 引号 / 反斜杠一律拒掉，而不是写出一个「看着成了」的坏值）。
set -euo pipefail

# `set -e` 的静默退出是排查黑洞：脚本半途死掉、stderr 空白。
# 任何未被 if/&& 接住的失败都把行号打到 stderr。
# 为什么用 $0 / $? 而不用中间变量：`$(basename "$0")` 是**命令替换**，
# 在同一个字符串里先展开它会把 `$?` 冲成 0（已实测），行号与退出码就都错了。
trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR


DOMAIN="${1:-}"
OUT_DIR="${2:-configs/web}"
VALUE_JSON="${OUT_DIR}/nginx.value.json"
STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# htpasswd 路径跟着变量走（gops 注入），没注入时与输出目录同居。
HTPASSWD="${WEB_HTPASSWD:-${OUT_DIR}/htpasswd}"
case "${HTPASSWD}" in
  /*) : ;;
  *) HTPASSWD="${STACK_ROOT}/${HTPASSWD}" ;;
esac

note() { echo "  $*"; }

if [[ -z "$DOMAIN" ]]; then
  echo "用法: $0 <域名> [输出目录]" >&2
  exit 2
fi

case "$DOMAIN" in
  *[!A-Za-z0-9.-]* | .* | *.)
    echo "域名不合法：'${DOMAIN}'（只允许 [A-Za-z0-9.-]，且不以点开头/结尾）" >&2
    exit 1
    ;;
esac

mkdir -p "$OUT_DIR"
tmp="$(mktemp "${OUT_DIR}/.nginx.value.XXXXXX")"
printf '{\n  "web_domain": "%s"\n}\n' "$DOMAIN" >"$tmp"
chmod 644 "$tmp"

if [[ -f "$VALUE_JSON" ]] && cmp -s "$tmp" "$VALUE_JSON"; then
  rm -f "$tmp"
  note "渲染值与当前一致（web_domain=${DOMAIN}），跳过：${VALUE_JSON}"
else
  mv -f "$tmp" "$VALUE_JSON"
  note "已写渲染值：${VALUE_JSON}（web_domain=${DOMAIN}）"
fi

###############################################################################
# 入口 basic auth（人）：密钥文件 → htpasswd（只存 apr1）
###############################################################################
#
# 为什么在这里而不是在容器里：容器里没有 gops，也不该为算一个摘要装一份；
# 而宿主机侧读密钥的**唯一**入口是 `gops sec get`（路径 / 权限 / 格式校验都在它那里）。
# 缺键直接失败，**不随机生成**：脚本生成的口令没人知道，而「页面打不开」比
# 「口令到底是啥」更难查——口令就在密钥文件里，看一眼或 `gops sec get --show` 即可。
sec_get() {
  local key="$1" out
  if ! command -v gops >/dev/null 2>&1; then
    echo "错误：读取密钥 \`${key}\` 需要 gops（>= 2.8）；请确认 gops 在 PATH 上" >&2
    return 1
  fi
  if ! ( cd "${STACK_ROOT}" && gops sec list --json >/dev/null ); then
    echo "错误：密钥文件不可用（sys-prj.yml: secrets.file = .wist/sec-value.yml）" >&2
    return 1
  fi
  out="$( cd "${STACK_ROOT}" && gops sec get --show "${key}" 2>/dev/null )" || out=""
  printf '%s' "${out}"
}

# 同一个口令 + 同一个 salt 算出来的 apr1 是确定的：先比对，没变就不重写。
# 重写会改 mtime（无意义的变更），也会让“这次到底换没换口令”变得难判断。
apr1_matches() {
  local password="$1" line="$2" salt
  salt="$(printf '%s' "${line}" | awk -F'\\$' '{print $3}')"
  [[ -n "${salt}" ]] || return 1
  [[ "$(openssl passwd -apr1 -salt "${salt}" "${password}")" == "${line#admin:}" ]]
}

password="$(sec_get web_entry_password)" || exit 1
if [[ -z "${password}" ]]; then
  cat >&2 <<'MSG'
错误：入口口令没有来源。

  .wist/sec-value.yml 里缺 web_entry_password。补上（口令就是下面生成的那串），
  或直接重跑 scripts/init-gateway.sh（它按缺补齐、不打印）：

    printf 'web_entry_password: "%s"\n' "$(openssl rand -hex 12)" >> .wist/sec-value.yml
    chmod 600 .wist/sec-value.yml
    gops sec fix

  然后重跑 gops sys localize（登录：用户名 admin，口令同上）。
MSG
  exit 1
fi

current=""
if [[ -f "${HTPASSWD}" ]]; then
  current="$(sed -n 's/^admin://p' "${HTPASSWD}" | head -n 1)"
fi
if [[ -n "${current}" ]] && apr1_matches "${password}" "${current}"; then
  note "入口口令与密钥文件一致，跳过：${HTPASSWD}"
else
  if ! hash="$(openssl passwd -apr1 "${password}")"; then
    echo "生成 htpasswd 失败（需要 openssl passwd -apr1）" >&2
    exit 1
  fi
  mkdir -p "$(dirname "${HTPASSWD}")"
  # 先写临时文件再替换：nginx 可能正读着，不留半截文件。
  tmp_pw="$(mktemp "${HTPASSWD}.XXXXXX")"
  printf 'admin:%s\n' "${hash}" >"${tmp_pw}"
  chmod 640 "${tmp_pw}"
  mv -f "${tmp_pw}" "${HTPASSWD}"
  note "已按密钥文件写入入口口令（用户名 admin，不回显）：${HTPASSWD}"
fi
