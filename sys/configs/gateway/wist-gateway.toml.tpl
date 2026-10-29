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
# === 这是一份「实现层」配置（impl）===
# “这台网关**对外是什么**”（对外基址 / 归属）**不在这里** —— 它在**站点身份目录**
# `identity/public/wist-gateway-pub.toml`（接口层，**现场态**，dev/prod 共用）**：那份由
# `scripts/init-gateway-pub.sh` 按缺补齐、**已有值一律保留**，不随模板重渲。网关加载时读**两份**
# （见 wist-gateway 的 `load_from_path`：段可以重合，**叶子键不许重复**；路径由
# `WIST_GATEWAY_PUB_CONFIG` 指定，见 sys/docker-compose.yml）。
#
# 证书 / 私钥 / 信任锚 / 签名密钥也在**站点身份**里（`identity/public|private/`，dev/prod 共用、
# 只读挂到 `/config/identity`）—— 它们不可重建、不该随渲染物一起被升级覆盖，故从 `state/` 拆出。
# `state/` 现在只剩**每部署一份**的 store 库。
# 分开的理由：本文件是**交付物**（升级/重渲该被覆盖），而对外基址与归属是**现场选择**
# （升级必须保留）—— 混在一个文件里时 `preserve` / `ignore` / `backup` 只能互相让步。
#
# 一个渲染占位（注意：pem/注释里不要再写同样的花括号占位，否则会被一并替换）：
#   victoria_metrics_url  网关查询观测后端（VictoriaMetrics）的地址。**随运行形态变**：
#                         发布态网关是容器，走 compose 服务名 http://victoria-metrics:8428；
#                         开发态网关是宿主进程，解析不到服务名，必须是宿主可达地址
#                         （如 http://127.0.0.1:18429）。默认值在 sys/setting/vars.yml 的
#                         VICTORIA_METRICS_URL。值取自 scripts/init-gateway.sh 写的渲染值。
#
# 管理台/管理 API 的 Bearer token **不在这里渲染成明文**：配置里写 `${SEC_ADMIN_TOKEN}`，
# 由网关加载时从密钥文件解析（`WIST_GATEWAY_SEC_FILE` 指向的 `.wist/sec-value.yml`，键 `admin_token`）。
#
# 可选段引用的一个渲染值（**空 = 不渲染该键**，由 scripts/init-knowledge-signing.sh 维护）：
#   knowledge_signing_pubkey  知识库内容包的验签公钥相对路径；空 = 不验签
[server]
listen_addr = "0.0.0.0:3000"
tls_cert_file = "identity/public/admin-tls.crt.pem"
tls_key_file = "identity/private/admin-tls.key.pem"
admin_api_token = "${SEC_ADMIN_TOKEN}"
victoria_metrics_url = "{{victoria_metrics_url}}"

[agent]
# agent CA：给 agent 签**客户端证书**（mTLS）。声明了它，注册/续期时网关就会用 agent 交的 CSR 签证书；
# 也是「换库/丢库后 agent 自动重建登记」的前提。两个文件由 scripts/init-gateway.sh 生成（同给或同缺）。
# （段名已含 `agent`，键名不再重复该前缀：这里是**给 agent 签字的 CA**，不是 agent 自己的证书。）
# 注：agent 侧仍用客户端证书校验网关（agent.trust_bundle_file = 网关 CA），两把 CA 各管一头。
ca_cert_file = "identity/public/agent-ca.crt.pem"
ca_key_file = "identity/private/agent-ca.key.pem"
bootstrap_ttl_seconds = 900
credential_ttl_seconds = 2592000
store_file = "state/wist-gateway-store.json"
trust_bundle_file = "identity/public/gateway-ca.crt.pem"

# 数据面（wparse）内部接入端点，仅 compose 内网可达。绑容器网卡（非默认的环回）是为了让
# wparse 容器连得上；明文 HTTP。
[ingest]
listen_addr = "0.0.0.0:3001"

# 本网关进程自己的运行日志（与「被采集 agent 日志的落盘保留」两回事，后者走 `[logs]`）。
# 落文件（相对配置目录解析 → 已挂载持久化的 `<config>/logs/`；自动建父目录），写满自轮转。
# 给了 `file` 就**不再**写 stderr（`docker logs` 看不到网关自身日志；打开失败会回落 stderr）；
# `RUST_LOG` 环境变量仍优先于下面的 level。
[log]
level  = "info"   # 或 "wist_gateway=debug,hyper=warn"
format = "text"   # 或 "json"（结构化行，便于日志采集）
file            = "logs/wist-gateway.log"
max_bytes       = 67108864   # 单文件上限（字节，写满轮转成 .1/.2/…；缺省 64 MiB）
keep_files      = 4          # 保留分卷数（0 = 不留历史；缺省 4）
max_seconds     = 604800     # 分卷保留时长（秒，0 = 不按时间清；缺省 7 天）

# 知识库（`[knowledge]`）：两个键各管一头，都不配也不会出错。
#
#   signing_public_key_file  内容包的**验签**：包只认发布侧（wist-knowledge CI）那把私钥签过的
#                            （设计 §9）。公钥由 scripts/init-knowledge-signing.sh 放到 identity/public/。
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

# 数据面（wparse）工作根 —— **只读**浏览用（管理面「数据采集 → 配置与规则」）。
#
# 宿主 `data-plane-run/work` 由 compose 只读挂到容器的 `/data-plane`
# （见 sys/docker-compose.yml）；页面从这里读 conf / topology / connectors / models。
# 「采集日志」页 tail 的输出目录按 wparse 的布局推导：`<work_dir>/data/out_dat`
# （宿主 `data-plane-run/data` 由 compose 只读挂到 `/data-plane/data`）。
#
# **故意不做存在性校验**：没挂载只让这一个页面回 503，不把网关挡在启动之外。
# 可浏览的范围由网关侧白名单决定（见 wist-gateway `api/data_plane.rs`），不是整棵目录。
[data_plane]
work_dir = "/data-plane"
