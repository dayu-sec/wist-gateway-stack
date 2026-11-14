# 由 gx.tpl 渲染 —— 不要手改。
# 模板：`sys/configs/harvest/harvest.toml.tpl`；渲染值：`configs/harvest/harvest.value.json`
# 改值：`sys/setting/vars.yml`（或 `values/` 覆盖）后重新 `gops sys localize`。

[service]
# **本地硬开关**：`false` = 进程常驻但不调度（healthcheck 只探活 + 检查 spool/state）。
# 真正的开/关与采集范围在网关（下面的 `[gateway]` standing）：这里 true 只代表「允许调度」。
# 现场要急停就改 false —— 网关授权也越不过这个关。
enabled = {{harvest_enabled}}
# 收齐之前不发送：一个采集范围的完整快照先落盘，再一次性发出。
spool_dir = "/var/lib/wist-harvest/spool"
state_dir = "/var/lib/wist-harvest/state"
page_size = 100
# 单帧上限：超限即 Aborted（推动下游支持分片组装，不拆 snap_id）。
max_frame_bytes = 33554432
max_response_bytes = 16777216
request_timeout_ms = 30000
concurrency = 1
# 空 ≠ 失败：只有范围完整且云端确实为空时才允许发空快照。
allow_empty = false

# 网关工作授权（worker 面，mTLS）：采什么 / 什么节奏由网关下发（standing）。
# 没有客户端证书时，用一次性接入券换一张（落在 `identity_dir/`，0600）。
[gateway]
endpoint = "{{harvest_gateway_endpoint}}"
source_code = "{{harvest_source_code}}"
poll_interval_ms = {{harvest_gateway_poll_ms}}
# 服务端信任锚（网关 TLS 证书的 CA）。自签站点必须给，否则握手失败。
ca_file = "{{harvest_gateway_ca_file}}"
# 身份目录（客户端证书 + 私钥，0600）。**必须落在于两个容器都挂了的 `state_dir` 里**：
# `harvest-bootstrap` 换来的证书要让 `run` 看得见，而且不能跟着容器重建丢掉。
identity_dir = "/var/lib/wist-harvest/state/identity"

# 一次性接入券：只在**没有客户端证书**时用。
# 同栈部署不需要它 —— `harvest-bootstrap` 用下面的 admin token 现签一张并**当场换成证书**
# （落在 `identity_dir/`，`run` 起来直接用）。这里配的是跨机部署 / 手工排障的券：
# 网关页「签发接入券」→ 写进宿主 `.wist/sec-value.yml` 的 `harvest_enroll_ticket`。
# 字段缺失**不是错误**（只是没有券可用）。
[gateway.enroll_ticket]
file = "/secrets/sec-value.yml"
field = "harvest_enroll_ticket"

# 管理面 token：**只给 `bootstrap` 子命令**签发接入券 / 建初始 standing；`run` 不读。
[gateway.admin_token]
file = "/secrets/sec-value.yml"
field = "admin_token"

[retry]
max_attempts = 4
base_delay_ms = 200
max_delay_ms = 5000

[rate]
default_qps = 5.0
default_burst = 5.0

[sink]
# 同栈 wparse 的**统一数据入口**（`tcp_1`，容器内 9000，`framing = "len"` / ndjson）。
# 与 agentd 上送同一个口、**同一个 `DSNAP:` 信封**：记录里的 `schema`
# （`atlas.in.inventory.v1`）决定下游走哪条路，数据面不需要为采集器加规则。
# **不要**改成对公网可达的地址（入口本身已发布到宿主，别再扩大范围）。
endpoint = "wparse:9000"
# 同栈内网明文（9000 无 TLS）。
allow_plaintext = true
connect_timeout_ms = 5000
# **不等 ACK**：warp-parse 的 tcp_src 只消费长度前缀帧、不回应答。
# 若设成 true，每次发布都会等到超时 → 运行永远 Aborted、spool 永不清理（帧其实已送达）。
expect_ack = false
ack_timeout_ms = 15000
publish_attempts = 3
