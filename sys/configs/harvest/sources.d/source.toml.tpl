# 由 gx.tpl 渲染 —— 不要手改。
# 模板：`sys/configs/harvest/sources.d/source.toml.tpl`；渲染值：`configs/harvest/harvest.value.json`
#
# 文件名固定 `source.toml`：`gx.tpl` 的 `dst` 不认变量，compose 里 `--source` 写的是同一个名字。
# 数据源的身份是文件里的 `source_code`（下游按它做资源匹配与作用域隔离），不是文件名。
#
# **这里没有客户 / 租户**：一个网关只服务一个客户，客户身份由发送通道在入库时打上
# （wparse 的全局 tag `tenant_id`，来自 gwlinkd 写入的 `WIST_TENANT_ID`），OML 用它拼
# `cust_id`。采集器不认识客户，也就不会把「客户」焊进采集配置。
#
# 关闭态（`HARVEST_ENABLED` 不为 true）渲染成**只有注释**：它是合法 TOML，但不是可用
# 数据源（缺 `source_code`）。于是「绕过 profile 硬起容器」会当场 `source_config` FAIL，
# 而不是拿一个空配置去云上把某个账号采一遍 —— 那种错是静默且彻底的。
{{#if harvest_enabled}}
source_code = "{{harvest_source_code}}"
# 厂商：选择适配器。**必填且显式** —— 不写/写错就启动失败，绝不猜。
vendor = "TENCENT_CLOUD"
group = "inventory"
env_ref = "{{harvest_env_ref}}"
# 地域：`"auto"` = 运行时用 DescribeRegions 解析；或固定列表（`HARVEST_REGIONS` 逗号分隔）。
regions = {{{harvest_regions_literal}}}

[assets]
cloud_host = true
eip = true
vpc = true
subnet = true

# 凭据只写「从哪读」，永远不写值。
# 与网关共用 `.wist/sec-value.yml`（扁平 YAML，`gops sec` 维护），`:ro` 挂进容器 `/secrets`。
# **不要**改成 env —— 那会让密钥出现在 `docker inspect` 里。
[credential]
secret_id = { file = "/secrets/sec-value.yml", field = "toc_secretid" }
secret_key = { file = "/secrets/sec-value.yml", field = "toc_secretkey" }
{{else}}
# ── 采集未启用（本文件不是可用数据源）────────────────────────────────────
# 原因：`HARVEST_ENABLED` 不是 true。
#
# 注意：服务是**常驻**的，没有 compose profile —— 未启用时容器照样在跑，只是不调度
# （healthcheck 只探活 + 检查 spool/state）。真正“开不开 / 采什么”的真相在网关
# （工作授权 standing，网关信息页「云资产采集」卡），采集器每 30 秒自己来拉一次。
#
# 启用步骤：
#   1. 网关 >= 0.48，`[gateway].endpoint` 指向 `https://gateway:8443`（TLS）
#   2. 网关页「云资产采集」卡签发接入券 → 写进 `.wist/sec-value.yml` 的 `harvest_enroll_ticket`
#   3. 启动后第一拍 poll 换取客户端证书（落在 state/identity/），再到页面上授权 standing
#   4. 凭据写进 `.wist/sec-value.yml`：`toc_secretid` / `toc_secretkey`
#
# 本文件在当前状态下不渲染（`HARVEST_ENABLED=false` 是本地硬关，容器常驻但不调度）。
{{/if}}
