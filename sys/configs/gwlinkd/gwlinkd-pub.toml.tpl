# wist-gwlinkd **现场态声明**（接口层）—— 只写 `${VAR}` 引用，**不含现场值**。
#
# 本文件是**模板**：由 tpl 机制渲染到 `identity/gwlinkd/gwlinkd-pub.toml`
# （见 `sys/workflows/operators.gxl`）—— 与其它交付物同一套渲染；重渲 / 升级动不到现场，
# 因为值不在这里。真值在同目录的 `.env`（docker-compose 口径：`.env` 挨着本文件；**进程环境优先**）。
#
# 变量名用 gops 的系统变量名，好让现场脚本“原样搬”：
#   CENTER_ENDPOINT / GWLINKD_GATEWAY_ID / GWLINKD_TRUST_BUNDLE
# 左侧是 gwlinkd 的配置键；网关「链接上级」页接入时，gwlinkd 会把值写进 `.env` 里
# **本文件声明的那个变量名**（见 wist-gwlinkd 的 `upsert_link_settings`）。
#
# `${VAR}` 未定义且没给 `:-默认值` → gwlinkd 拒启（fail-closed）。
# 这里三个都写全，避免“忘了跑安装脚本”只能看到“端点未配置”这种远端的症状。

# 上级控制中心地址（空 = 尚未接入）
control_center_endpoint = "${CENTER_ENDPOINT}"

# 本网关在中心侧的标识（须与中心实例名一致）
gateway_id = "${GWLINKD_GATEWAY_ID}"

# 中心 CA-S 信任锚路径（自签中心必需；公网中心可留空 → 回落系统根）
trust_bundle = "${GWLINKD_TRUST_BUNDLE:-}"

# 一次性接入券（由「链接上级」页写入 `.env`；接入成功后 gwlinkd 会删掉那一行）
link_token = "${GWLINKD_LINK_TOKEN:-}"
