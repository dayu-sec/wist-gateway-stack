# wist-gwlinkd 主配置模板（handlebars，由 gx.tpl 渲染）。
#
# 渲染：gops sys localize（阶段流程 localize）—— tpl=本文件，data=gwlinkd.value.json，
#       dst=configs/gwlinkd/gwlinkd.toml；渲染值由 scripts/init-gwlinkd.sh 写。
#
# gwlinkd 是网关**宿主侧**常驻（CR-003）：把本网关接入上级控制中心。
#
# **本文件是交付物**：只放「随部署环境渲染」的项 —— 升级 / 重渲**该**覆盖它。
# 现场选择（上级中心地址 / 本网关在中心侧的标识 / 中心信任锚）与一次性接入券 `link_token` 在
# **现场态**（**声明 + 值分开**，docker-compose 口径）：
#   · 声明 `identity/gwlinkd/gwlinkd-pub.toml` —— 只写 `${VAR}` 引用（由 tpl 机制渲染；值不在这里，
#     所以重渲 / 升级动不到现场）；
#   · 值   `identity/gwlinkd/.env` —— 现场真值（scripts/init-gwlinkd-pub.sh 按缺补齐；gwlinkd 在
#     「链接上级」页完成接入时写入）。**脚本只写这个值文件，不动声明 toml**。
# gwlinkd 加载时读**两份**（段可重合、**叶子键不许重复**）—— 归属唯一，不靠加载顺序。
# 身份材料（客户端证书 + 私钥、中心信任锚）落 `identity_dir`：它进 `sys-prj.yml` 的 `contract`
# （不可再生、不进包、必进备份），所以与本文件分离。
#
# 只参数化**随部署环境变化**的量；`state_dir` 等相对路径是应用契约。
#
# 占位（注意：注释里不要再写同样的花括号占位，否则会被一并替换）：
#   state_dir              运行态目录（单实例锁 / 升级簿记 / 临时注册券；可删可重建）
#   identity_dir           身份目录（客户端证书 + 私钥、中心信任锚）—— 进 contract；空 = 不渲染（回落 state_dir）
#   gateway_self_endpoint  本机网关环回面（页面路才需要；空 = 不渲染该项）
#   gateway_self_ca        环回面信任锚（空 = 不渲染，用系统根）
#   agent_package_drop_dir        发布 ② 投放目录（宿主侧；空 = 不渲染该项，② 不启用）
#   agent_package_container_dir   该目录在网关容器里的路径（如 /packages）
#   upgrader_program       升级执行器程序（空 = 不渲染，用 gwlinkd 缺省 gops）
#   upgrade_project_dir    gops 工程根（含 ops-prj.yml；空 = 不渲染。用 gops 执行器升级时必配，**绝对路径**）
state_dir = "{{state_dir}}"
{{#if identity_dir}}
identity_dir = "{{identity_dir}}"
{{/if}}
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

# ── WarpParse 管理面中继（WarpStation 发布链路）──
# Center 的 wparse-proxy 把发布/状态请求写入命令队列；gwlinkd 轮询取命令，
# 用本机回环 HTTPS + admin token 调 wparse（容器内 0.0.0.0:19090，宿主只发布 127.0.0.1）。
# **注意**：该段需要在支持 `[wparse_relay]` 的 gwlinkd 版本上才生效；旧版会忽略。
[wparse_relay]
enabled = {{{wparse_relay_enabled}}}
upstream = "{{{wparse_relay_upstream}}}"
ca_file = "{{{wparse_relay_ca}}}"
token_file = "{{{wparse_relay_token}}}"
poll_interval_ms = 1500
request_timeout_ms = 20000
allowed_paths = ["/admin/v1/reloads/model", "/admin/v1/runtime/status"]
