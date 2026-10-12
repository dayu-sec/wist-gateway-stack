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
#   agent_package_drop_dir        发布 ② 投放目录（宿主侧；空 = 不渲染该项，② 不启用）
#   agent_package_container_dir   该目录在网关容器里的路径（如 /packages）
#   upgrader_program       升级执行器程序（空 = 不渲染，用 gwlinkd 缺省 gops）
#   upgrade_project_dir    gops 工程根（含 ops-prj.yml；空 = 不渲染。用 gops 执行器升级时必配，**绝对路径**）
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
# 升级（gwlinkd 驱动 gops）：`upgrade_project_dir` 是 gops 工程根（含 ops-prj.yml）。
# gops 从 **cwd** 解析工程、且 `gops prj upgrade` 没有“指定工程”的旗标 ⇒ 用 gops 执行器时必配。
{{#if upgrader_program}}
upgrader_program = "{{upgrader_program}}"
{{/if}}
{{#if upgrade_project_dir}}
upgrade_project_dir = "{{upgrade_project_dir}}"
{{/if}}
# 发布 ②「Agent 包交付」：gwlinkd 取到中心包后，落到宿主投放目录（agent_package_drop_dir），
# 再把**容器内路径**（agent_package_container_dir/<文件名>）交给网关托管。
# 两项指向**同一份**目录（宿主写法 vs 容器写法）—— 容器里的路径就是 compose 里 `:/packages`。
# 缺这两项则 ② fail-closed（收到 push-agent-package 计划会报错）。
{{#if agent_package_drop_dir}}
agent_package_drop_dir = "{{agent_package_drop_dir}}"
{{/if}}
{{#if agent_package_container_dir}}
agent_package_container_dir = "{{agent_package_container_dir}}"
{{/if}}
