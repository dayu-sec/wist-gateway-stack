# wist-gateway-web 站点配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/web/nginx.conf.tpl）
# dst: configs/web/nginx.conf（**不直接给 nginx**：sys/docker-compose.yml 把它挂到 /etc/nginx/wist/nginx.conf.in，
#      再由容器入口包装 sys/web/web-entrypoint.sh 把 admin token 拼进去、写成 /etc/nginx/conf.d/default.conf）
# 渲染值：configs/web/nginx.value.json（scripts/init-web-conf.sh 从环境变量 WEB_DOMAIN 生成）
#
# 职责：443 上终止 TLS + **入口认证** + 托管前端静态产物 + SPA 深链回退 + 把 /api 反代到网关容器。
# 证书用**本页自己的**（scripts/init-web-tls.sh 生成），与网关证书分开 —— 网关私钥不进 web 容器。
# 与开发态 vite 代理对齐：/api 前缀保留、忽略网关自签证书。
#
# ⚠ 本文件是**交付物**（模板 + nginx.value.json 渲染出来的），**不能含密钥**：
#   管理面 Bearer 用占位符 `@WIST_GATEWAY_ADMIN_TOKEN@`，由容器启动时的
#   `sys/web/web-entrypoint.sh` 从密钥文件（/secrets/sec-value.yml）拼进来。
#   直接挂本文件给 nginx 用是**错的** —— 那样占位符会原样发出去（全部 401）。

server {
    listen 443 ssl;
    server_name {{web_domain}};

    ssl_certificate     /certs/public/web-tls.crt.pem;
    ssl_certificate_key /certs/private/web-tls.key.pem;

    root /usr/share/nginx/html;
    index index.html;

    # ── 入口认证（人）───────────────────────────────────────────────
    # 整站都要，包括首屏 `/`：只护 `/api/` 会变成「页面先出来、第一次请求才弹认证框」，
    # 用户一取消就是一片 401 —— 看着像「没有登录入口」。
    # 口令在栈根密钥文件（`.wist/sec-value.yml` 的 web_entry_password），
    # 由 scripts/init-web-conf.sh 算成 apr1 摘要写进 configs/web/htpasswd。
    # 换口令 = 改密钥 + `gops sys localize` + 重启 web（nginx 只在启动时读 htpasswd）。
    auth_basic           "wist-gateway";
    auth_basic_user_file /etc/nginx/htpasswd;

    # Docker 内嵌 DNS：upstream 名在**运行时**解析（配合下面的变量式 proxy_pass）。
    # valid=3s：网关重建 / 换 IP 后最多 3s 生效，不需要重启 web 容器。
    resolver 127.0.0.11 valid=3s ipv6=off;

    # 静态资源 + SPA 深链回退：找不到实体文件就交给前端路由（index.html）。
    location / {
        try_files $uri $uri/ /index.html;
    }

    # /api 反代到网关（容器内 3000，自签 HTTPS）。
    # **必须走变量**：字面量 proxy_pass 只在 nginx 启动时解析一次，网关没起来（或容器换 IP）
    # 就会 `[emerg] host not found in upstream "gateway"` 直接退出 → web 跟着网关反复重启。
    # 走变量后每个请求由 resolver 解析；不带 URI 仍然原样透传 /api/...（与 vite 代理一致）。
    location /api/ {
        set $gateway_upstream https://gateway:3000;
        proxy_pass $gateway_upstream;
        proxy_ssl_server_name on;
        proxy_ssl_verify off; # 网关是自签证书，内网直连，不做证书链校验
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 管理面 Bearer：**浏览器不再持 token** —— 入口验过人之后由这里补上。
        # 占位符在容器启动时由 sys/web/web-entrypoint.sh 从密钥文件替换；
        # 客户端自带的 Authorization 一律被覆盖（外部塞进来的凭据不能进网关）。
        # 直连网关端口（GATEWAY_PORT，默认 443）的机器仍然自己带 Bearer —— 那是机器面，不走这一道。
        proxy_set_header Authorization "Bearer @WIST_GATEWAY_ADMIN_TOKEN@";
    }
}
