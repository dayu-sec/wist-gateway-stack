#!/usr/bin/env bash
# 入口认证（人）的回归测试：口令从密钥文件来、缺了就不放行、摘要幂等；
# 以及容器入口包装把 admin token 拼进 nginx 配置（这一半需要 docker，没有就跳过）。
#
#   ./dev/tests/web-entry-auth.test.sh
#
# 钉住的行为：
#   ① 密钥文件缺 web_entry_password → `init-web-conf.sh` 失败（不随机生成口令）；
#   ② 有键 → htpasswd 的 apr1 与口令对得上、模式 0640、不含明文；
#   ③ 同一口令重跑不重写（mtime 不变）；换口令 → 重写且旧口令失效；
#   ④ `sys/web/web-entrypoint.sh` 把 @WIST_GATEWAY_ADMIN_TOKEN@ 换成密钥里的 admin_token，
#      产物不含占位符、模式 0600；
#   ⑤ admin_token 缺失 / 含非法字符 → 明确失败（而不是带着占位符起、让所有 /api 401）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${HERE}/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }

mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

###############################################################################
# ①–③ 宿主机侧：密钥 → htpasswd
###############################################################################
echo "① 密钥 → htpasswd（scripts/init-web-conf.sh）"

SANDBOX="${TMP}/stack"
mkdir -p "${SANDBOX}/.wist" "${TMP}/bin"
cp -R "${STACK_ROOT}/scripts" "${SANDBOX}/scripts"
SEC_FILE="${SANDBOX}/.wist/sec-value.yml"
HTPASSWD="${SANDBOX}/configs/web/htpasswd"

# 假 gops：只实现 `sec list` / `sec get --show`，语义与真的一致
# （文件不存在 → 非零；键不存在 → 非零；成功 → 只打值）。
cat >"${TMP}/bin/gops" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
sec_file="${FAKE_SEC_FILE:?}"
case "${1:-} ${2:-}" in
  "sec list")
    [[ -f "${sec_file}" ]] || { echo "密钥文件不存在" >&2; exit 1; }
    echo '{"items":[]}'
    ;;
  "sec get")
    shift 2
    [[ "${1:-}" == "--show" ]] && shift
    [[ -f "${sec_file}" ]] || exit 1
    value="$(sed -n "s/^${1}:[[:space:]]*//p" "${sec_file}" | tail -n 1)"
    value="${value%\"}"
    value="${value#\"}"
    [[ -n "${value}" ]] || exit 1
    printf '%s\n' "${value}"
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "${TMP}/bin/gops"
export PATH="${TMP}/bin:${PATH}"
export FAKE_SEC_FILE="${SEC_FILE}"

run_web_conf() {
  ( cd "${SANDBOX}" && WEB_HTPASSWD="${HTPASSWD}" ./scripts/init-web-conf.sh example.test configs/web )
}

htpasswd_matches() {
  local line salt
  line="$(sed -n 's/^admin://p' "${HTPASSWD}" | head -n 1)"
  [[ -n "${line}" ]] || return 1
  salt="$(printf '%s' "${line}" | awk -F'\$' '{print $3}')"
  [[ -n "${salt}" ]] || return 1
  [[ "$(openssl passwd -apr1 -salt "${salt}" "$1")" == "${line}" ]]
}

# 缺键（文件在、键不在）
printf 'admin_token: "deadbeef"\n' >"${SEC_FILE}"
out="$(run_web_conf 2>&1)"; rc=$?
[[ ${rc} -ne 0 ]] && ok "缺 web_entry_password → 退出码 ${rc}" || no "缺键时应当失败"
grep -q '入口口令没有来源' <<<"${out}" && ok "提示「入口口令没有来源」" || no "缺少错误提示"
[[ ! -f "${HTPASSWD}" ]] && ok "没有生成 htpasswd" || no "不该生成 htpasswd"

PW1="$(openssl rand -hex 12)"
printf 'admin_token: "deadbeef"\nweb_entry_password: "%s"\n' "${PW1}" >"${SEC_FILE}"
chmod 600 "${SEC_FILE}"
out="$(run_web_conf 2>&1)"; rc=$?
[[ ${rc} -eq 0 ]] && ok "有键 → 退出码 0" || { no "应当成功，实际 ${rc}"; printf '%s\n' "${out}" >&2; }
htpasswd_matches "${PW1}" && ok "apr1 与密钥对得上" || no "apr1 与密钥不符"
[[ "$(mode_of "${HTPASSWD}")" == "640" ]] && ok "模式 0640" || no "模式应为 0640（实际 $(mode_of "${HTPASSWD}")）"
grep -q "${PW1}" "${HTPASSWD}" 2>/dev/null && no "明文口令不该出现在 htpasswd 里" || ok "htpasswd 里没有明文"

before="$(mtime_of "${HTPASSWD}")"
sleep 1
run_web_conf >/dev/null 2>&1
[[ "$(mtime_of "${HTPASSWD}")" == "${before}" ]] && ok "同口令不重写（mtime 不变）" || no "文件被无谓重写"

PW2="$(openssl rand -hex 12)"
printf 'admin_token: "deadbeef"\nweb_entry_password: "%s"\n' "${PW2}" >"${SEC_FILE}"
run_web_conf >/dev/null 2>&1
htpasswd_matches "${PW2}" && ok "换口令后新口令生效" || no "新口令未生效"
if htpasswd_matches "${PW1}"; then no "旧口令仍然有效"; else ok "旧口令已失效"; fi

###############################################################################
# ④–⑤ 容器侧：入口包装把 admin token 拼进配置
###############################################################################
echo "④ 入口包装：admin_token → nginx 配置"

if ! command -v docker >/dev/null 2>&1; then
  echo "  跳过（没有 docker）"
else
  # 用本地已有的 nginx 镜像（哪个 tag 都行）；一个都没有就跳过 —— 不为了测试去拉镜像。
  IMG="${NGINX_TEST_IMAGE:-$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | awk '/^nginx:/{print; exit}')}"
  if [[ -z "${IMG}" ]]; then
    echo "  跳过（本地没有 nginx 镜像；可设 NGINX_TEST_IMAGE 指定）"
  else
    echo "  （镜像：${IMG}）"
  WORK="${TMP}/hook"
  mkdir -p "${WORK}/in" "${WORK}/out" "${WORK}/secrets"
  cat >"${WORK}/in/nginx.conf.in" <<'TPL'
server {
    listen 80;
    location /api/ {
        proxy_set_header Authorization "Bearer @WIST_GATEWAY_ADMIN_TOKEN@";
    }
}
TPL
  # 用 `true` 当 CMD：官方 entrypoint 只对 `nginx` 做初始化，其余直接 exec —— 不起服务。
  run_hook() {
    docker run --rm \
      --entrypoint /bin/sh \
      -e WIST_WEB_CONF_IN=/in/nginx.conf.in \
      -e WIST_WEB_CONF_OUT=/out/default.conf \
      -e WIST_GATEWAY_SEC_FILE=/secrets/sec-value.yml \
      -v "${WORK}/in:/in:ro" \
      -v "${WORK}/out:/out" \
      -v "${WORK}/secrets:/secrets:ro" \
      -v "${STACK_ROOT}/sys/web/web-entrypoint.sh:/opt/wist/web-entrypoint.sh:ro" \
      "${IMG}" /opt/wist/web-entrypoint.sh true 2>&1
  }

  # ⑤a 缺密钥文件
  out="$(run_hook)"; rc=$?
  [[ ${rc} -ne 0 ]] && ok "缺密钥文件 → 退出码 ${rc}" || no "缺密钥文件时应当失败"
  grep -q '缺密钥文件' <<<"${out}" && ok "报错说清缺什么" || no "缺少「缺密钥文件」提示"

  # ⑤b 有文件但缺 admin_token
  printf 'web_entry_password: "x"\n' >"${WORK}/secrets/sec-value.yml"
  out="$(run_hook)"; rc=$?
  [[ ${rc} -ne 0 ]] && ok "缺 admin_token → 退出码 ${rc}" || no "缺 admin_token 时应当失败"
  grep -q 'admin_token' <<<"${out}" && ok "报错提到 admin_token" || no "报错没提 admin_token"

  # ⑤c 非法字符（会破坏 sed / nginx 引号）
  printf 'admin_token: "ab|cd"\n' >"${WORK}/secrets/sec-value.yml"
  out="$(run_hook)"; rc=$?
  [[ ${rc} -ne 0 ]] && ok "非法字符 → 退出码 ${rc}" || no "非法字符时应当失败"

  # ④ 正常注入
  TOKEN="$(openssl rand -hex 24)"
  printf 'admin_token: "%s"\n' "${TOKEN}" >"${WORK}/secrets/sec-value.yml"
  out="$(run_hook)"; rc=$?
  [[ ${rc} -eq 0 ]] && ok "正常 → 退出码 0" || { no "应当成功，实际 ${rc}"; printf '%s\n' "${out}" >&2; }
  grep -q "Bearer ${TOKEN}" "${WORK}/out/default.conf" 2>/dev/null \
    && ok "配置里是真实 token" || no "配置里的 token 不对"
  grep -q '@WIST_GATEWAY_ADMIN_TOKEN@' "${WORK}/out/default.conf" 2>/dev/null \
    && no "占位符没被替换干净" || ok "占位符已替换"
  [[ "$(mode_of "${WORK}/out/default.conf")" == "600" ]] \
    && ok "产物模式 0600" || no "产物模式应为 0600（实际 $(mode_of "${WORK}/out/default.conf")）"
  fi
fi

echo
printf '通过 %d，失败 %d\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]
