#!/bin/sh
# web 容器的入口包装（compose 里 `entrypoint: ["/bin/sh", "/opt/wist/web-entrypoint.sh"]`）。
#
# 职责：把「渲染好的站点配置」与「密钥文件里的 admin token」合成真正的 nginx 配置，
# 然后把控制权交回官方 nginx entrypoint（`/docker-entrypoint.sh`）——它仍然照常跑
# 自己的初始化脚本并 exec nginx。
#
# 为什么用 `sh <文件>` 而不是 `/docker-entrypoint.d/40-xxx.sh`：
#   官方镜像只执行**带可执行位**的钩子，而本栈的 bind 挂载权限统一由 `gops sys perms`
#   按只读语义收敛（执行位不在承诺里）—— 一旦丢了执行位，钩子会被**静默跳过**，
#   症状是页面正常打开、所有 /api 全 401。显式用 `sh` 调起就不依赖执行位了。
#   （也不写成 `*.envsh`：那份是源码方式执行，而官方 entrypoint 把它放在 `find | while`
#   的子 shell 里，`export` 出不来——实测过。）
#
# 为什么要在这里拼：
#   · `configs/web/nginx.conf` 是**交付物**（模板 + value.json 的产物）：随版本覆盖、进备份、
#     能被任何人 `cat`。admin token 绝不能渲染进去；
#   · token 只在栈根密钥文件 `.wist/sec-value.yml`（0600、不进包）里，nginx 自己不会读 YAML，
#     所以只能在这一步 —— nginx 解析配置之前 —— 取一次。
#
# 输入 / 输出：
#   /etc/nginx/wist/nginx.conf.in      渲染物（含 @WIST_GATEWAY_ADMIN_TOKEN@ 占位）
#   /secrets/sec-value.yml             密钥文件（只读挂载，与网关容器用的是同一份）
#   /etc/nginx/conf.d/default.conf     真配置（0600：含 token，只有 master 读）
set -eu

IN="${WIST_WEB_CONF_IN:-/etc/nginx/wist/nginx.conf.in}"
OUT="${WIST_WEB_CONF_OUT:-/etc/nginx/conf.d/default.conf}"
SEC="${WIST_GATEWAY_SEC_FILE:-/secrets/sec-value.yml}"
MARKER="@WIST_GATEWAY_ADMIN_TOKEN@"

die() {
  echo "web-conf: $*" >&2
  exit 1
}

# ⚠ 本脚本在**容器里**跑：没有 gops，也不该为了拼一份配置装一份。
#   挂进来的 /secrets 属主是宿主部署账号、与容器内 uid 不同，gops 的属主校验会（正确地）拒绝。
#   所以这里保留最小解析 —— 与 wist-center-stack 的 scripts/db-init.sh 同一个取舍；
#   宿主机侧的脚本一律走 `gops sec get`。
get_secret() {
  secret_value="$(sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "${SEC}" | head -n1 | tr -d '\r')"
  case "${secret_value}" in
    '""' | "''") secret_value="" ;;
    \"*) secret_value="${secret_value#\"}"; secret_value="${secret_value%\"}" ;;
    \'*) secret_value="${secret_value#\'}"; secret_value="${secret_value%\'}" ;;
  esac
  printf '%s\n' "${secret_value}"
}

[ -f "${IN}" ] || die "缺站点配置模板：${IN}（localize 没渲染？先跑 gops sys localize）"
[ -f "${SEC}" ] || die "缺密钥文件：${SEC}（栈根的 .wist/ 没挂进来？）"

TOKEN="$(get_secret admin_token)"
[ -n "${TOKEN}" ] || die "${SEC} 缺 admin_token —— 网关的管理面 Bearer 与页面注入都靠它"

# 只允许不会破坏 sed 替换、也不会破坏 nginx 引号的字符。本项目的 token 是 hex，
# 这里放宽到常见 token 字符集；出现别的字符直接失败，而不是让 sed 把配置写坏。
case "${TOKEN}" in
  *[!A-Za-z0-9._~+/=-]*) die "admin_token 含不支持的字符（只允许 [A-Za-z0-9._~+/=-]）" ;;
esac

umask 077
sed "s|${MARKER}|${TOKEN}|g" "${IN}" >"${OUT}.tmp"
mv -f "${OUT}.tmp" "${OUT}"

# 占位符必须被替换干净：模板改坏了也别带着占位符起 —— 那样所有 /api 都是 401，
# 现场看起来像「token 不对」，实际是配置没合成。
if grep -q "${MARKER}" "${OUT}"; then
  die "站点配置里仍有未替换的 ${MARKER}（模板里有别的写法？）"
fi

echo "web-conf: 已注入管理面 Bearer（来自 ${SEC}）→ ${OUT}"

# 交回官方 entrypoint：它还会跑自己的初始化脚本，最后 exec nginx。
# 没带参数时（例如 `docker run` 把 CMD 也覆盖了）补上镜像的默认 CMD —— 否则
# `/docker-entrypoint.sh` 什么都不会 exec，容器立刻退出，表现只看得见一条 "ready for start up"。
[ "$#" -gt 0 ] || set -- nginx -g "daemon off;"
exec /docker-entrypoint.sh "$@"
