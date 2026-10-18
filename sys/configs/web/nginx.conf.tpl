# wist-gateway-web 站点配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/web/nginx.conf.tpl）
# dst: configs/web/nginx.conf（sys/docker-compose.yml 把它挂到 /etc/nginx/conf.d/default.conf；站点身份目录 identity/web 挂到 /certs）
# 渲染值：configs/web/nginx.value.json（scripts/init-web-conf.sh 从环境变量 WEB_DOMAIN 生成）
#
# 职责：443 上终止 TLS + 托管前端静态产物 + SPA 深链回退 + 把 /api 反代到网关容器。
# 证书用**本页自己的**（scripts/init-web-tls.sh 生成），与网关证书分开 —— 网关私钥不进 web 容器。
# 与开发态 vite 代理对齐：/api 前缀保留、忽略网关自签证书。

server {
    listen 443 ssl;
    server_name {{web_domain}};

    ssl_certificate     /certs/public/web-tls.crt.pem;
    ssl_certificate_key /certs/private/web-tls.key.pem;

    root /usr/share/nginx/html;
    index index.html;

    # Docker 内嵌 DNS：upstream 名在**运行时**解析（配合下面的变量式 proxy_pass）。
    # valid=10s：网关重建 / 换 IP 后最多 10s 生效，不需要重启 web 容器。
    resolver 127.0.0.11 valid=10s ipv6=off;

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
    }
}
