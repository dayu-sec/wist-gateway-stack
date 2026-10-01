# wist-gateway 运行配置模板（handlebars，由 gx.tpl 渲染）。
#
# 渲染：
#   gops sys localize                （阶段流程 localize，合并变量后自动跑；gops>=1.3.4/gx>=0.14）
#   或单独：gx run -e debug localize
#   （见 _gal/work.gxl；tpl=本文件，data=wist-gateway.value.json，dst=wist-gateway.toml）
#
# 只参数化**随部署环境变化**的量；其余（监听地址、相对路径、TTL）是应用契约或固定值，
# 保持字面量，不因环境而变。
#
# 三个占位（注意：pem/注释里不要再写同样的花括号占位，否则会被一并替换）：
#   public_base_url       对外基址，须落在网关 TLS 证书 SAN 内、且是 https://
#   admin_api_token       管理台/管理 API 的 Bearer token（密钥，不要入库）
#   victoria_metrics_url  网关查询观测后端（VictoriaMetrics）的地址。**随运行形态变**：
#                         发布态网关是容器，走 compose 服务名 http://victoria-metrics:8428；
#                         开发态网关是宿主进程，解析不到服务名，必须是宿主可达地址
#                         （如 http://127.0.0.1:18429）。默认值在 sys/setting/vars.yml 的
#                         VICTORIA_METRICS_URL。值取自 scripts/init-gateway.sh 写的渲染值。
#
# 可选段引用的一个渲染值（**空 = 不渲染该段**，由 scripts/init-knowledge-signing.sh 维护）：
#   knowledge_signing_pubkey  知识库内容包的验签公钥相对路径；空 = 不验签
[server]
listen_addr = "0.0.0.0:3000"
public_base_url = "{{public_base_url}}"
tls_cert_file = "state/admin-tls.crt.pem"
tls_key_file = "state/admin-tls.key.pem"
admin_api_token = "{{admin_api_token}}"
victoria_metrics_url = "{{victoria_metrics_url}}"

[agent]
# agent CA：给 agent 签**客户端证书**（mTLS）。声明了它，注册/续期时网关就会用 agent 交的 CSR 签证书；
# 也是「换库/丢库后 agent 自动重建登记」的前提。两个文件由 scripts/init-gateway.sh 生成（同给或同缺）。
# 注：agent 侧仍用客户端证书校验网关（agent.trust_bundle_file = 网关 CA），两把 CA 各管一头。
agent_ca_cert_file = "state/agent-ca.crt.pem"
agent_ca_key_file = "state/agent-ca.key.pem"
bootstrap_token_ttl_seconds = 900
credential_ttl_seconds = 2592000
store_file = "state/wist-gateway-store.json"
trust_bundle_file = "state/gateway-ca.crt.pem"
install_script_signing_private_key_file = "state/install-script-signing-ed25519.pkcs8.pem"
tenant_id = "tenant-default"
environment_id = "env-default"

# 数据面（wparse）内部接入端点，仅 compose 内网可达。绑容器网卡（非默认的环回）是为了让
# wparse 容器连得上；明文 HTTP。
[ingest]
listen_addr = "0.0.0.0:3001"

# 知识库（`[knowledge]`）：两个键各管一头，都不配也不会出错。
#
#   signing_public_key_file  内容包的**验签**：包只认发布侧（wist-knowledge CI）那把私钥签过的
#                            （设计 §9）。公钥由 scripts/init-knowledge-signing.sh 放到 state/。
#                            给了就必须验过才允许录入；配了却读不到/不是公钥，网关会拒绝启动。
#   source_dir               **启动期知识源**（出厂初始包）：管理面还没激活过可用包时用它；
#                            一旦管理面切了可用包，包就接管（优先级见网关 `app/knowledge.rs`
#                            的 `resolve`）。内容由 `gops sys localize` 里的 gx.download +
#                            scripts/install-initial-knowledge.sh 备好。
#
# `knowledge/initial` 是**应用契约**（相对本配置目录的固定值，不随环境变）—— 与
# scripts/install-initial-knowledge.sh 的落点必须一致，**改一处要同时改另一处**。
[knowledge]
{{#if knowledge_signing_pubkey}}
signing_public_key_file = "{{knowledge_signing_pubkey}}"
{{/if}}
source_dir = "knowledge/initial"
