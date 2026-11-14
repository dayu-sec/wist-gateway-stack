# 由 gx.tpl 渲染 —— 不要手改。
# 模板：`sys/configs/harvest/harvest.toml.tpl`；渲染值：`configs/harvest/harvest.value.json`
# 改值：`sys/setting/vars.yml`（或 `values/` 覆盖）后重新 `gops sys localize`。

[service]
# **本地硬开关**：`false` = 进程常驻但不调度（healthcheck 只探活 + 检查 spool/state）。
# 真正的开/关在中心（下面的 `[control]`）：这里 true 只代表「允许调度」。
# 现场要急停就改 false —— 中心说 true 也越不过这个关。
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

# 中心配置轮询：开关的真相在中心（gateway 的 harvest_setting），采集器自己定时问一句。
# `url` 为空 = 不轮询（用上面的 [service] enabled）。需要 gateway >= 0.47.0-alpha。
[control]
url = "{{harvest_control_url}}"
poll_interval_ms = {{harvest_control_poll_ms}}

# token 复用管理面 token（部署取舍）：harvest 只需读，但 token 是同一个 ——
# 所以 harvest 的出网面必须收窄到同栈内网。
[control.credential]
bearer = { file = "/secrets/sec-value.yml", field = "admin_token" }

[retry]
max_attempts = 4
base_delay_ms = 200
max_delay_ms = 5000

[rate]
default_qps = 5.0
default_burst = 5.0

[sink]
# 同栈 wparse 的**统一数据入口**（`tcp_1`，容器内 9000，`framing = "len"` / ndjson）。
# 与 agentd 上送同一个口：两者靠 WPL 的 `CLOUDINV:` 标记区分，路由按 OML 名分。
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
