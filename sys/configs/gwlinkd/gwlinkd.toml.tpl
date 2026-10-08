# wist-gwlinkd 本机配置模板（handlebars，由 gx.tpl 渲染）。
#
# 渲染：gops sys localize（阶段流程 localize）—— tpl=本文件，data=gwlinkd.value.json，
#       dst=configs/gwlinkd/gwlinkd.toml；渲染值由 scripts/init-gwlinkd.sh 写。
#
# gwlinkd 是网关**宿主侧**常驻（CR-003）：把本网关接入上级控制中心。
# **一次性接入券 `link_token` 不在模板里**：由网关「链接上级」页提交、gwlinkd 拉到后**写回本文件**
# （见 wist-gwlinkd 的 `upsert_link_settings`）；已注册后不要再动这些项。
#
# 只参数化**随部署环境变化**的量；`state_dir` 等相对路径是应用契约。
#
# 占位（注意：注释里不要再写同样的花括号占位，否则会被一并替换）：
#   center_endpoint        上级控制中心地址（空 = 尚未接入）
#   trust_bundle           中心 CA-S 信任锚路径（自签中心必需）
#   state_dir              gwlinkd 状态/身份目录
#   gateway_id             本网关在中心侧的标识
#   gateway_self_endpoint  本机网关环回面（页面路才需要；空 = 不渲染该项）
#   gateway_self_ca        环回面信任锚（空 = 不渲染，用系统根）
control_center_endpoint = "{{center_endpoint}}"
trust_bundle = "{{trust_bundle}}"
state_dir = "{{state_dir}}"
gateway_id = "{{gateway_id}}"
{{#if gateway_self_endpoint}}
gateway_self_endpoint = "{{gateway_self_endpoint}}"
{{/if}}
{{#if gateway_self_ca}}
gateway_self_ca = "{{gateway_self_ca}}"
{{/if}}
