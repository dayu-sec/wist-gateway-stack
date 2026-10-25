# 更新日志

本文件记录 `wist-gateway-stack` 的所有重要变更。格式遵循 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [0.2.18-alpha] - 2026-10-25

### 变更

- **前端跟版 `v0.14.2-alpha`**：
  - 容器名过滤在页面可见：`filters.name_in` / `name_not_in` 渲染成 `container in [...]` /
    `container not in [...]`（旧网关不下发这两个键时不报错）；
  - Gateway 信息页按用途重组：三段改成「看 / 改 / 状态」——`当前配置` 合并成三列表、
    `修改上送设置` 只留表单、`接入上级` 补上 gwlinkd 心跳与中心地址。
- 网关 / 知识库版本不变（`v0.20.4-alpha` / `0.5.4`）。

### 升级注意

- 这次只换前端镜像，采集行为不变。
- 若站点用的是 agentd `0.9.7-alpha`，自观测里会多一行
  `telemetry selection filtered … magnitude=excluded=N identity_unknown=M`（无过滤配置时不出现）。

## [0.2.17-alpha] - 2026-10-24

### 变更

- **网关跟版 `v0.20.4-alpha`**：
  - `match` 装载期 fail-closed：漏 `:` / 漏 `;` / 拼错 kind 不再静默
    （漏冒号会让否定条件消失 → 双采；漏分号会让单元永不展开）；
  - 容器过滤器的**减法维度**（`pod_not_in` / `name_not_in`）在旧 agent 上**去掉维度继续采**，
    不再整条裁源 —— 单来源容器单元不会因缺一维能力变成“面不可授权”；
  - 容器日志来源判据改用契约共享实现，接受目录形态（`…/containers`）。
- **出厂知识库包 `v0.5.4`**（`purpose_version = 3`）：新增 `dockerd` / `containerd` →
  `LinuxCompute` 的用途判据 —— **只跑业务容器的纯 Docker 主机**现在也能拿到容器 stdout 面
  （以前落 `LinuxHost`，模板不带 `linux-workload`，单元根本派不到）。
- 前端版本不变（`v0.14.1-alpha`）。

### 升级注意

- ⚠ `not_path_exists` 是**整机级开关**：`k8s(containerd) + 独立 dockerd` 的混跑主机、
  以及 `/var/log/containers` 残留目录的主机会少采 / 不采 docker 容器 stdout。
  逃生口：授权时显式点名 `spec=linux-docker-container-stdout`（不再保证去重）。
- 已激活过知识包的站点：录入并激活 0.5.4 → **重新授权**（用途建议与模板展开用新规则）。
  spec 在授权那一刻固化：先确认 agent 已上报 `/var/log/containers`（`probed_paths`），
  否则 docker 单元会落 `fact_not_collected`，需要再授权一次。

## [0.2.16-alpha] - 2026-10-24

### 变更

- **网关跟版 `v0.20.3-alpha`**：`match` 支持否定条件 `not_path_exists:<绝对路径>`（三态求值、
  路径进探测白名单、装载期校验）；`filters.name_in` / `name_not_in` 的装载校验按维度分开
  （name 维度放宽到含 `containers/` 的来源，namespace/pod 仍限 `/var/log/containers`）。
- **出厂知识库包 `v0.5.3`**（`catalog_version` 12）：`linux-docker-container-stdout` 的 `match`
  加 `not_path_exists:/var/log/containers` —— `k8s + cri-dockerd` 的主机上不再与
  `linux-container-stdout` 重复采集同一份日志。前端版本不变（`v0.14.1-alpha`）。

### 升级注意

- **组件升级顺序**：网关 → 主机上的 agentd（≥ 0.9.5 才有容器名过滤能力）→ 知识库包。
  旧网关不认识 `not_path_exists` 时该单元整条不展开（保守，不会重采）。
- ⚠ **已激活过知识包的站点只升 stack 不会换目录**：需要在「知识库」页把 0.5.3 的包**录入并激活**
  （热加载），再**重新授权 `ComputeWorkload`**，并等一轮策略拉取（≤5 分钟）让
  `/var/log/containers` 进入探测白名单。
- 容器名过滤（`filters.name_in` / `name_not_in`）是**可选量控**，出厂目录里没启用。

## [0.2.15-alpha] - 2026-10-24

### 变更

- **出厂知识库包 `v0.5.2`**：新增 `linux-docker-container-stdout` —— 纯 Docker 主机的容器
  stdout（`/var/lib/docker/containers/*/*-json.log*`）。正文原样上送，docker 的 JSON 信封
  由数据面解（与 CRI 头同层），因此**采集端零代码**、也不影响旧版本 agentd。
  网关与前端版本不变（`v0.20.2-alpha` / `v0.14.1-alpha`）。

### 升级注意

- 授权后**正文暂时是原始 JSON 行**（`{"log":…,"stream":…,"time":…}`）—— 解码规则在数据面
  （下一步）。这次先把字节拿回来，偏移/续读/轮转都是正常的。
- ⚠ **k8s + cri-dockerd 的主机会重复采集**（kubelet 的 pod 日志指向 docker 的 json 文件），
  否定条件落地前别把这类机器纳入 `linux-workload` 包。纯 Docker 主机不受影响。
- 日志量取决于容器数量与活跃度；单轮读取量受 `max_read_bytes_per_tick` 限制，
  首次授权从 `tail` 开始。

## [0.2.14-alpha] - 2026-10-24

### 变更

- **网关跟版 `v0.20.2-alpha`**：
  - 派活被拒的文案带上卡住的那条条件（`linux-db-service=fact_not_collected(path_exists:/var/log/postgresql)`）；
  - 管理面「发现策略」页的 `probe_paths` 改为网关**实际下发**的那一份（与 agent 收到的同源）。
  前端 `v0.14.1-alpha`、出厂知识库包 `v0.5.1` 不变。

### 升级注意

- **机队要升到 agentd `0.9.2` 及以上**：0.9.1 及以前会丢掉网关下发的探测白名单，
  于是 `path_exists:` 判定的面（auth / sudo / audit / kernel / 数据库 / 容器 stdout）
  在真机上**永远授不了权**（`work_conflict: … fact_not_collected`）。
  0.9.3 进一步把这处转换收成契约里的唯一实现（`DiscoveryAspectPolicySet::from`）。

## [0.2.13-alpha] - 2026-10-24

### 变更

- **组件跟版**：网关 `v0.20.1-alpha`、前端 `v0.14.1-alpha`。带来日志采集侧的
  「能力轴补全」与两种记录边界读法（`postgres_csv` / `mysql_slow`）、噪音行丢弃
  （`drop_if_contains`，**不占 `seq`**），以及事实摘要 `fact-v3`。同面仍为 `draft` 的单元
  不再随面一起派下去。
- **出厂知识库包 `v0.5.1`**：新增容器 stdout 单元（13 / 15 / 16），数据库面（csvlog / slow log）
  翻 `active`，`auth.log` / `secure` 配噪音行；`catalog_version` 10。

### 升级注意

- **滚动顺序**：先本 stack（网关、前端，含 contracts 能力轴）→ 机队 agentd `0.9.1` → 再推目录。
  旧网关会整份拒收新 agentd 的能力上报；机队没到 agentd ≥ 0.9.1 前，新读法会被当成
  「一行一条」读，csvlog / slow log 记录会被切碎。
- **知识库包到 `packages/` ≠ 生效**：升级后需在「知识库」页用本地来源录入再点激活。
- **`fact-v3` 升级后会全网重新上报一次事实**（摘要前缀变了），属预期，不是故障。

## [0.2.12-alpha] - 2026-10-23

### 修复

- **`wparse` 因 `cp -a` 保留时间戳失败而无限重启**：现场日志
  `cp: preserving times for '/data/conf/.': Operation not permitted`，容器 `exit 1`、重启 12 次。
  `-a` 隐含 `-p`，会对目标**目录**写回时间戳；而工作根属主是部署账号（`gops sys perms` 对齐），
  容器（999）不是属主 → `EPERM` → `cp` 退 1 → `set -e` 放大成重启循环。
  入口补种子改为 `cp -R --update=none`（单文件同）：只补缺失，不保留时间/属主；
  不再依赖 `conf/connectors/models/topology` 的属主是谁。
- `init-wparse-admin.sh` 与 README 的“老现场一次性 chown”从**整棵 work/** 收窄到检测到的
  **挂载点**，并说明：0.2.12 之前不要把 `conf/connectors/models/topology` 改成部署账号属主
  （旧入口的 `cp -a` 需要它属于容器用户）。

## [0.2.11-alpha] - 2026-10-23

### 工程

- **`wist-stackcheck` 汇总行不再打印为 0 的段**（`wist-stackcheck-core` 0.1.4）：
  `23 项检查：20 ok / 3 warn（结论：warn）`，不再出现 `0 fail` —— 日志查看器 / CI 的
  关键词高亮会把 `fail` 涂红，读起来像“有失败”。总数仍在句首，信息不丢；全好时就是 `N 项检查：N ok`。

## [0.2.10-alpha] - 2026-10-23

### 修复

- **`data-plane-run/work` 里的嵌套挂载点被 Docker 以 root 创建，导致 `gops sys perms --apply`
  整片失败**（`d data-plane-run/work/.run 2755 0:999 → 2770 1000:999 [failed]`，属主 `0`）。
  父挂载 `${WPARSE_RUN_WORK}:/data` 生效后，`/data/data`、`/data/.run`、`/data/identity/*`
  这些子挂载点只能落在**宿主**工作目录里；缺失时由 Docker 守护进程以 root 建（空目录/空文件），
  部署账号既不能 `chown` 也不能 `chmod`。
  `scripts/init-wparse-admin.sh` 现在在 `localize` 阶段（早于 `perms --apply`）**以部署账号预建**
  `work/{data,.run,identity,identity/trust}` 与 `identity/admin-tls.*.pem`；Docker 看到已存在
  就不再创建。老现场会打印一行带 `sudo chown -R "$(id -u)":999 data-plane-run/work` 的提示。
- compose 注释同步修正：之前写「挂载点都建在容器层里、宿主目录保持干净」是不对的。

## [0.2.9-alpha] - 2026-10-23

### 修复

- **`wparse` 因「信任锚被 docker 建成目录」而无限重启**（现场 `restarting` 52 次，日志
  `sink error → build victoriametric client failed`；`exit_code=1`）。
  链路：`identity/gwlinkd/control-center.pem` 缺失时，compose 里那条**单文件** bind 会被 docker
  **静默建成一个同名空目录**（不报错）；`SSL_CERT_FILE` 指到它之后，引擎构造 HTTP 客户端
  （reqwest）失败 ⇒ **每个** sink 都建不起来 ⇒ 进程退出、容器重启循环。症状看着像「连不上
  VictoriaMetrics」，而 VictoriaMetrics 一直是健康的。

  **断根方式（结构契约，不只是打补丁）** —— 中心信任锚是**可选**的（公网 CA 的中心用不到、
  中心还没接入时也不存在），两个状态都必须能跑：

  1. **容器不再挂单文件**：只挂目录 `identity/gwlinkd/trust/`（可能为空），docker 就没有把
     文件建成目录的机会；
  2. **真身与投影分开**：真身仍是 `identity/gwlinkd/control-center.pem`（gwlinkd 页面接入时
     写的就是它，不动）；`scripts/init-gwlinkd-pub.sh` 每次 localize 建目录并投影：
     有可读 PEM 就拷过去，没有就**删掉投影**（不留陈旧 CA）；
  3. **入口脚本兜底**：投影不是可读 PEM 时 `unset SSL_CERT_FILE` / `GIT_SSL_CAINFO`
     （回落系统根）并打一行 info —— 文件再缺也不会拖死容器。

### 工程

- **`identity.trust_anchor`（新）**：信任锚路径是**目录**（docker 建的）或不是 `BEGIN CERTIFICATE`
  ⇒ **阻断 FAIL**，并给出 `rmdir` 的修法；文件缺失仍按「回落系统根」放行。
- **`identity.trust_projection`（新）**：真身与容器投影必须同步（缺失/陈旧 → WARN，
  提示跑 `gops sys localize`）；两头都没有 = 合法现场，报 OK。
- **`layout.bind_source_type`（新）**：compose 里**文件类** bind 源（容器目标末段含 `.`，如
  `*.pem` / `*.toml` / `*.conf`）在宿主上必须是文件；「源是目录、目标像文件」直接 FAIL。
  变量源（`${PACKAGE_DIR}`）与缺失源不在此判。
- **`identity.gwlinkd_paths` 的相对路径解析**：`GWLINKD_TRUST_BUNDLE=./identity/...` 原先
  按进程 CWD 判存在，`--root` 指到别处时会把正常部署报成悬空；改为相对**栈根**解析。
- `scripts/init-gwlinkd-pub.sh` 额外清掉信任锚位置上的**空目录**（只删空目录）：那是 docker
  留下的残骸，会把「CA 写回原位」永久堵死。
- 新增脚本回归 `dev/tests/init-gwlinkd-pub.test.sh`：空目录清理 / 非空目录不碰 / 真 PEM 幂等 /
  死键清理 / 投影同步与撤销 / 投影位被占时明确报错。

## [0.2.8-alpha] - 2026-10-23

### 组件

- **初始知识库 `0.5.0`**（`KNOWLEDGE_PATH = v0.5.0/wist-knowledge-0.5.0.tar.gz`）：
  `linux-kernel-system` 改为 `Exporter journalctl-kernel`（`journalctl -k -p 4 -o json`，
  游标续读、周期 60s），并用 `match = "path_exists:/run/systemd/journal"` 在非 systemd 主机上
  不展开（不做文件回退）；`catalog_version` 8 → 9。
- 网关 / 前端 / 观测 / wparse 镜像不变，仍是 `v0.20.0-alpha` / `v0.14.0-alpha` /
  `victoria-metrics v1.154.0` / `warp-parse 0.32.1-alpha`。

### 升级提示

- **顺序：先装/升级本栈（含 agentd 0.9），再让知识库 0.5.0 生效**：旧网关不认识
  `journalctl-kernel`，会把整份目录判为非法（装载失败）；旧 agentd 会把该单元如实报 `unsupported`。
  本栈的初始包指针已经是 0.5.0 —— 升级到本版本即等同于把它推下去，**别在网关 / agentd 之前
  单独换知识库**。
- 已跑过 `localize` 的现场会因文件名变化重新下载（`gx.download` 按 URL 判重）；
  旧版本包留在 `packages/` 不影响，只是历史。

### 修复

- **初始知识库只拉包、不拉签名旁文件**：`packages/` 是现场态（不入库，`localize` 每次重下拉），
  而 `localize` 的 `gx.download` 只拉 `wist-knowledge-<版本>.tar.gz` —— 新装的栈因此停在
  「有包、没 `.sig`」，配了验签公钥（公钥随栈交付）的网关在管理面「本地来源」录入时报
  **422 `package_signature_invalid`**，`wist-stackcheck` 也会报 `package.knowledge_signature`。
  `localize` 里补上第二个 `gx.download`（`<包>.sig`，与包同目录；两个 URL 各自 `reuse_cache`，
  「包在、签名缺」时也只补拉签名）—— 制品源缺这份旁文件会在 localize 就失败，不再装出
  「有包没签名」的栈。`install-initial-knowledge.sh` 核对它在不在、缺了告警但不阻断
  （启动期知识源 `source_dir` 不验签，与 stackcheck 该判据的非阻断口径一致）；
  `import-knowledge.sh` 手工导入时也把源目录的 `.sig` 一并拷过去。

### 工程

- **新增 `prereq.container_gid`**：从 compose 里**有 bind 挂载的非 root 服务**的 `user:` 派生容器 gid，
  与当前进程的组（`/proc/self/status`）比对；缺组就 FAIL 并给出 `groupadd` / `usermod -aG`。
  `localize` 第一步的 `--gate --only prereq` 因此能在任何写盘之前拦住——它对应
  `gops sys perms --apply` 整片 `Operation not permitted`（`0 项待修 / N 项失败`）的真正原因。
  命名卷、root 服务、非数字 `user:` 分别不参与 / 不参与 / 只 WARN。

## [0.2.7-alpha] - 2026-10-23

### 组件

- **网关 `v0.20.0-alpha`**：采集目录支持容器选源过滤器（`namespace_in` / `pod_not_in`），
  并按 agent 自报的日志能力裁剪派活（旧 agentd 行为不变）；内核面改走 journald 后无需网关侧改动。
- **前端 `v0.14.0-alpha`**：过滤器直接渲染成「ns in [...]」「pod not in [...]」；
  「内核与系统」不再被误标成「未接」。
- 观测镜像与 wparse 未动（`victoria-metrics v1.154.0` / `warp-parse 0.32.1-alpha` 已确认在 TCR）。

### 升级提示

- **先升级本栈，再升级 agentd**：新网关才收得下 agentd 0.9 上报的能力清单
  （旧网关会整份拒收状态报文）。
- 知识库 `0.5.0`（内核面改走 journald）可在本栈升级后再推给网关；
  旧网关不认识 `journalctl-kernel`，会把整份目录判为非法。

### 工程

- **`tools/stackcheck` 的通用引擎抽到公共仓 `wist-stack-tools/stackcheck-core`**（tag 固定）：
  Flow Result / CLI / 渲染/密钥/端口/镜像/compose/x509 只有一份实现；本仓保留 gateway profile、
  package / knowledge / identity / prereq / TLS 策略与薄 main。
- 共享引擎顺带修掉两栈已经分叉的边界（判据数量不变，仍 19 项）：
  - `docker ps --format` 多行输出按 `,` + `\n` 切分（之前每行第一个发布端口会被静默漏掉，导致
    本栈端口误报冲突）；
  - 端口短语法支持 `[::1]:…` 与行内 `ports: […]`（之前静默跳过 = 假绿）；
  - `.env` 存在但不可读/为空时不再静默回落默认值；
  - 只有渲染产物、找不到值文件/模板时报 WARN（不再报 OK）；
  - 端口按 compose 的 bind IP 探测，镜像探测去重。
- 本地自检：`cargo test --manifest-path tools/stackcheck/Cargo.toml` 现在会拉取公共 core（首次需网络）。
- **补齐「权限与运行身份」的**一次性宿主前置：`gops sys perms --apply` 以部署账号身份只做
  `chmod`/`chgrp`，不在容器 gid（`999`）组里时整片挂载一起报 `Operation not permitted`
  （结论 `0 项待修 / N 项失败`）；README 与「主机要求」表给出 `groupadd` / `usermod -aG`
  与重登验证的具体步骤。

## [0.2.6-alpha] - 2026-10-23

### 修复

- **升级在 `regenerate` 阶段静默失败（无任何可读报错）** —— 现场表现为「打完两行 CA note 就 exit 1，
  stderr 空白」。根因不是证书逻辑：`init-gateway.sh` 用了 `openssl x509 -ext`，而 **macOS 自带的
  LibreSSL 不支持该选项**；升级流程由 gwlinkd 派生，它的 PATH 里没有 Homebrew，解析到的正是它。
  `set -e` + `pipefail` 让管道直接退出，`2>/dev/null` 把原因一起吞掉。
  - 新增 `scripts/lib/tls-san.sh`：SAN 的读取与「是否覆盖域名」**只此一处实现**，改用
    `x509 -text`（两种实现都支持），与 `tools/stackcheck` 的 `san_covers` 同口径；
    读不出时告警并按「不覆盖」重签，不再静默。
  - `init-web-tls.sh` 顺带修同类问题：原来在升级 PATH 下**每轮都重签** web 证书（且是子串匹配）。
- **两处「裸反引号被当命令替换执行」**：`init-knowledge-signing.sh` 的报错文案
  （实际输出 `-----BEGIN: command not found`，关键信息丢失）、`restore-gateway.sh` 的恢复后自检标题
  （真跑了一遍 stackcheck 并把输出塞进标题）。
- **`sed … | head -n1` 在 `pipefail` 下的 SIGPIPE 静默退出**：知识库 `manifest.json` 出现多处
  `"version"` 时整个 localize 退 141（用 123 KB manifest 复现 3/3）；`init-gateway` / `import-*` /
  `show-wparse-state` 的同类位置一并改掉。
- **知识库验签公钥指纹在 LibreSSL 下恒为空**：`openssl pkey -pubin` 读不了 Ed25519 公钥，
  且原先依赖只有 macOS 才有的 `shasum`。改用 python3 对 PEM 的 DER 取 sha256，两个平台一致
  （仍是 `502d6b90a96afb0b…`），并有测试钉住。
- `shasum` 不再硬编码（`import-package` / `import-knowledge` 回落 `sha256sum`）；
  `init-gateway` / `init-knowledge-signing` 缺 python3 时前置报错，不再半途死掉。
- ERR trap 的提示自身也是错的：`$(basename "$0")` 是命令替换，同串里会先把 `$?` 冲成 0。
  改为 `trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR`。

### 新增

- **`wist-stackcheck` 增加 `prereq.*`（判据 17 → 19）** —— 判的是「这台机器能不能跑这个栈的 localize」，
  不是「栈生成的东西对不对」：
  - `prereq.toolchain`：`bash` / `openssl` / `python3` / sha256 工具在**当前 PATH** 与
    **守护进程最低 PATH**（`/usr/bin:/bin:/usr/sbin:/sbin`）下是否都在。当前 PATH 缺 → **阻断**；
    只有守护进程的 PATH 缺 → **WARN**（本机能用，不拦开发机）。
  - `prereq.tls_san_reader`：用**随包** `scripts/lib/tls-san.sh` 在两份 PATH 下各读一次叶证书 SAN。
    「读不出」与「**静默读空**」（老实现在 LibreSSL 下的形态：退出 0、输出为空）都算失败，
    并在 detail 里点明用的是哪份 openssl。「随包 helper 缺失」单独一类（修法是重新解包，不是换 openssl）。
  - `--only <前缀>`：只跑一组判据；`flow localize` **开头**新增
    `./scripts/check-stack.sh --gate --only prereq` —— 前置条件不成立时，在改证书/回滚**之前**就失败。
    不用全量闸门放开头是因为那一刻包刚换完、还没重渲，`render.freshness.*` 会合理地判 FAIL。

### 工程

- `dev/tests/`：新增 `localize-cert-paths`（42 条）、`knowledge-signing-fingerprint`（16 条），
  并给知识库测试加「大 manifest 不许 SIGPIPE」一组。**全部故意用守护进程的最小 PATH 跑**
  （macOS 那一路才能复现 LibreSSL / bash 3.2 的差异）。
- `./dev/lint.sh`：shellcheck 两道 —— `-S warning`（错误/警告）+ `-S style --include=SC2006`（反引号，
  默认会被 `-S warning` 过滤掉）。CI 与本地跑的是同一条命令。
- CI：新增 `scripts.yml`（`scripts/**`、`dev/**`、`sys/**` 变更即跑，**ubuntu + macOS 双平台**）；
  `release.yml` 新增 shellcheck 且 `package` 依赖它与脚本测试 —— 脚本不干净就出不了包。
- README「开发态」补「本地自检」三项（lint / 脚本回归 / 检查器单测）与「为什么要换 PATH」。

## [0.2.5-alpha] - 2026-10-23

### 新增

- **`wist-stackcheck`：栈级配置检查器**（`tools/stackcheck` + `scripts/check-stack.sh`）。
  只查**栈自己生成的东西**，17 项判据：
  - `package.*`：投放目录 / 容器路径 / compose 挂载三者与 `PACKAGE_DIR` 派生值自洽；
    **键落在别的 TOML 段**时明确指出真实位置（本次现场故障的判据）；
  - `render.freshness.*`：渲染产物不得早于它的值文件（改了值没重渲）；
  - `render.placeholder`：渲染产物里还有 `example.com` 之类占位值；
  - `secret.*`：栈根密钥与私钥不得对其他用户开放（按内容识别私钥，不靠文件名猜）；
  - `package.knowledge_signature*`：最新知识库包必须有 `.sig`，历史包缺失只计数。
  输出对齐 `gops run diagnose` 的 Flow Result v1（`schema_version` + `checks[]`），
  设了 `GOPS_DIAGNOSE_RESULT` 时始终退出 0（结论在 `checks[]` 里），否则退出码即判定。

  分工：**栈检查器管文件与约定**（模板渲染、挂载、包配对），**组件管自己的键语义**
  （`deny_unknown_fields` + `diagnose`）—— 只有组件知道键是什么意思。

- **体检接入**：`flow diagnose` 现在跑两段——wparse 漂移（重建结果文件）+ 栈级检查（**追加** `checks[]`）。
  结果文件已有合法 Flow Result 时追加而不是覆盖，所以一个 flow 里多个诊断动作不会互相吞掉。
  注：栈级检查必须排在重建者之后。

- **升级/部署守门**：`flow localize` 末尾挂 `scripts/check-stack.sh --gate`。
  因为 `gops prj upgrade` 的 `regenerate` 阶段跑的就是 `gops sys localize` ——
  **新模板渲染出来是错的，会在 `pull` / `up` 之前就暴露**，并由 `--on-failure rollback-all` 回滚；
  首次部署也一样（`docker compose up` 之前就拦）。

  > 
  > 升级流水线里**只有这一道**是自动拦截：`prj upgrade` 的 `diagnose` 步用的是项目级
  > `project_diagnose`（values / sys_models / contract），**不跑**系统的 `flow diagnose`。
  > 想看全量体检得手工跑 `gops run diagnose`。

  闸门只看**阻断类**失败：WARN、以及「失败但不阻断」都不拦。目前唯一的不阻断项是
  知识库包缺 `.sig` —— 它让「以后导入」失败，但当前跑着的栈是好的，不该因此卡住升级。

  闸门优先级高于结果文件模式：环境里恰好存在 `GOPS_DIAGNOSE_RESULT` 时，
  「结果模式始终退 0」不能把守门绕过。

  另有三组判据把原来只在脚本里「闪一下」的提示变成常驻体检（`diagnose` 与闸门都覆盖）：
  - `identity.signing_pubkey`：配了知识库验签公钥就必须找得到它在三个候选落点之一
    （栈根 / `configs/gateway/` / `identity/gateway/`）；缺失不阻断，但以后导入会 422。
  - `identity.gwlinkd_paths`：`state_dir` / `identity_dir` / `GWLINKD_TRUST_BUNDLE`
    指向不存在的路径时提示（悬空信任锚会让 gwlinkd 报 UnknownIssuer）。
  - `knowledge.initial_layout`：`configs/gateway/knowledge/initial/` 的五份数据文件必须齐
    （`install-initial-knowledge.sh` 只在解包那一刻校验过，之后没人再管）。
  - `tls.san_covers_domain`：网关叶证书必须在有效期内，且 SAN **精确**覆盖 `WEB_DOMAIN`
    （支持 `*.example.com` 但只覆盖一层）。原来 `init-gateway.sh` 里是
    `openssl x509 … | grep -q "DNS:${domain}"` —— 正则 `.` 是通配符、且是子串匹配，
    证书 SAN 为 `gw.example.com.evil.net` 时也会放过。
  - `port.available`：宿主端口是否真的空着。排除**本栈自己**已发布的端口
    （按 compose 项目名认出本栈容器 —— 用 `workdir` 标签会在栈目录改过位置后漏掉自己）；
    其余端口做 bind 试探，被别的进程占就报**阻断类** FAIL（`compose up` 必然失败）。
  - `image.reachable`：镜像在源上是否存在。**本地已有的直接跳过网络**（55ms），
    其余并行取 manifest（各 6s 超时）；整个站点离线时收敛成**一条** WARN 而不是按镜像刷屏。
    离线站点用 `--offline` 或 `STACKCHECK_OFFLINE=1` 关掉。

  > 后两项需要宿主 `docker` CLI；不可用时分别报「无法确认端口归属」/「docker 不可用」，不误报。

- **`restore-gateway.sh` 还原后自检**：恢复完成时对栈根跑一次检查（只读），把
  「文件写回去了但互相矛盾」当场报出来，而不是等下次 `localize`。不改变恢复的退出码。

### 修复

- **检查器拿的是默认值，不是生效值**：原先只读 `sys/merged_vars.yml`，而那是 gops 的
  **INITIAL**（`sys localize` 输出的 INITIAL 列），生效值写在栈根 `.env`。站点一旦覆盖
  `PACKAGE_DIR`（完全合法的现场选择），路径自洽就永远对不上 —— 而这条一旦误判，
  就是「升级被闸门拦住」。现在优先读 `.env`，没有才回落默认值并在 detail 里写明来源。
  同一处也修了 `WEB_DOMAIN`（证书 SAN 判定）：它不仅看错值，还因为字段在 `[server]` 段
  而不是文档根而报「没有 tls_cert_file」。

- **`public_base_url` 是派生值但只在新建时写**（`scripts/init-gateway.sh`）：
  `value.json` 已存在时只同步 `victoria_metrics_url`，域名之后怎么改都不再落进去。
  典型症状：脚本拿着 `https://gw.example.com` 去 POST——**占位值不会报错，只会连到不存在的域名**
  （知识库导入就踩过）。现在显式给了 `WEB_DOMAIN` 就同步对齐。

- **`push-agent-package` 计划必然失败（「未配置 agent_package_drop_dir」）**：
  `agent_package_drop_dir` / `agent_package_container_dir` 被渲染在 `[[upgrade.component]]` **之后**，
  按 TOML 规则它们属于最后一个 component 表，gwlinkd 在文档根读到的是 `None` → ② 走 fail-closed。
  两项已移到所有段头之前，并加注「必须写在任何段头之前」，避免以后被挪回去。

### 变更

- **② Agent 包交付区独立到 `packages/agents`**：gwlinkd 交付后按 mtime 只保留最新 N 份，
  且 `prune_drop_dir` **不区分文件类型** —— 与知识库包、人工投放包共用 `packages/` 时，
  多交付几轮就会把 `wist-knowledge-*.tar.gz` 及其 `.sig` 当旧的删掉。
  现在宿主落 `<PACKAGE_DIR>/agents`、容器路径为 `<GWLINKD_AGENT_PACKAGE_CONTAINER_DIR>/agents`
  （同一个 compose 挂载，不需要新增 volume）。

- **发布包内含栈检查器**：CI 为 `x86_64-unknown-linux-musl` / `aarch64-unknown-linux-musl` /
  `aarch64-apple-darwin` 三个平台编译 `wist-stackcheck`，`tar -rf` 追加到**同一个**部署包里
  （`bin/<triple>/`）。制品仍是平台无关的单包、同一个下载地址，升级协议不用改；
  体积 +约 2 MB（单平台 672 KB）。其他架构运行时会明确报错（不静默跳过）。

### 升级注意

- 旧部署的交付文件还在 `packages/` 根下；升级后重派一次 `push-agent-package` 计划即可
  （网关按 platform **upsert**，不会留重复条目），随后可手工清掉根目录里的旧文件。
- **`localize` 现在会因配置阻断类 FAIL 而失败**（升级时即回滚）。如果现场被拦，按输出里的
  `code` 逐条处理；确认是误判时先用 `scripts/check-stack.sh` 手工跑一遍看全文。

## [0.2.4-alpha] - 2026-10-22

### 变更

- **初始知识库包地址拆成「源基址 + 稳定路径」**：`ARTIFACT_HOME` 现在包含**仓库 + 发布渠道前缀**
  （COS 镜像或 GitHub 的 `…/releases/download`），`KNOWLEDGE_PATH` 只写**跨源稳定**的
  `<版本>/<文件名>`。换制品源/换网络**只改 `ARTIFACT_HOME`**，不再需要跟着改路径。
  - 缺省源改为 COS 镜像：`https://github-1347593047.cos.ap-hongkong.myqcloud.com/wist-knowledge`，
    `KNOWLEDGE_PATH = v0.4.0/wist-knowledge-0.4.0.tar.gz`。
  - 直连 GitHub 时把 `ARTIFACT_HOME` 覆盖成
    `https://github.com/dayu-sec/wist-knowledge/releases/download` 即可（路径不变）。

### 升级注意

- **覆盖过 `ARTIFACT_HOME` 的部署要跟着改**：旧口径里它是裸基址（如 `https://github.com/dayu-sec`），
  现在要写成**含仓库/渠道前缀**的形式，否则拼出来的地址会 404。
- COS 镜像需要**随知识库发版同步**：新版本（如 `v0.5.0`）上传到 `wist-knowledge/v0.5.0/…` 后，
  只改本栈的 `KNOWLEDGE_PATH` 版本段即可；`gx.download` 按文件名判重，不会复用旧包。
- `gx.download` 对已存在的同名包会跳过（`reuse_cache`）；网络不可达时仍可把包手工放进
  `packages/` —— `install-initial-knowledge.sh` 会照常解包并在缺包时明确报错。

## [0.2.3-alpha] - 2026-10-22

### 变更

- **网关 `v0.19.0-alpha` / 前端 `v0.13.0-alpha`**：采集目录接受「文件族」来源 ——
  `FileGlob` 的目标可以是绝对路径 + 单层 glob（`*` 不跨目录、`**` 不支持），
  并可声明 `exclude_globs` 把不该采的文件剔掉；页面同步显示排除项与可采判定。
- **初始知识库 `0.4.0`**：`audit.log` 改为整文件采集（`linux-audit-log`，8 个 `host_audit_*`
  由数据面按 `type=` 分派），auth 面加 `path_exists` 门控（Debian 派 `auth.log`、RHEL 派 `secure`，
  不存在的路径在派活时被裁掉）。

### 升级注意

- **agentd 需 `0.8.0-alpha` 才能采文件族**：旧 agentd 会把 glob 来源如实报成 `unsupported`
  （不影响其它面）。知识库里靠通配的单元仍是 `draft`，等机队升级验证后再单独发一版目录翻 `active`。
- 本版目录里没有单元声明 `exclude_globs`，所以**网关不必与目录同版**；将来目录一旦带上排除项，
  就需要网关 ≥ 0.19。
- 初始知识库版本变了：`gops sys localize` 会重新下载并覆盖 `configs/gateway/knowledge/initial/`
  （该目录是生成物，不入库）。

## [0.2.2-alpha] - 2026-10-22

### 修复

- **gwlinkd 开发态安装兼容中心布局**（`dev/install-gwlinkd-dev.sh`）：当
  `/usr/local/bin/wist-gwlinkd` 是指向 `/usr/local/lib/wist-gwlinkd/wist-gwlinkd` 的符号链接时，
  按**真身**替换（不再把符号链接换成 root 属主的普通文件）；同时保证真身目录与文件归运行用户，
  避免中心推送的 gwlinkd 自更新在 preflight 写探测处 `EACCES`。服务定义仍以入口路径为准。
- **站点目录搬家后自愈信任锚路径**（`scripts/init-gwlinkd-pub.sh`）：`.env` 里路径型现场值
  （`GWLINKD_TRUST_BUNDLE`）指向的文件已不存在、而现场态目录下 `control-center.pem` 确实存在时，
  自动改写回期望位置；自定义路径仍有效则保留，两边都没有只告警、不猜。解决搬家后
  gwlinkd 回落系统根、自签中心报 `UnknownIssuer`。

### 升级注意

- 本次**不改组件 tag**（gateway `v0.18.1-alpha` / web `v0.12.1-alpha` / wparse `0.32.1-alpha` / VM `v1.154.0`），
  升级只需替换 stack 包，再 `gops sys localize`（会对 `.env` 重新做一次路径自愈）。
- TCR 里 `warp-parse:0.32.1-alpha` 仍未同步（推送 401：当前账号没有 `cloud/warp-parse` 的 push 权限）；
  只拉 TCR 的现场升级前，先用有权限的账号补推。

## [0.2.1-alpha] - 2026-10-22

### 变更

- **wparse `0.31.1-alpha` → `0.32.1-alpha`**（`wp-motor v1.33.0`）。该版本把**管理面配置移出远程托管目录**，
  并修复远程同步后模型文件可能缺失（缓存 checkout 改为 hard reset）。
- **`[admin_api]` 迁到项目根 `wparse.local.toml`**：从 `sys/data-plane/conf/wparse.toml` 拆到
  `sys/data-plane/wparse.local.toml`。`[project_remote]` 的 infra 同步会整体替换 `conf/`，旧写法会在
  每次远程发布后把 `admin_api.bind` 重置成远端模板值，导致管理端口失效。
  - 优先级：`wparse.local.toml` > `conf/wparse.toml` 中遗留的 `[admin_api]`（旧文件仍可启动，但会告警）。
  - 种子补缺：`wparse` 容器 entrypoint 与 `dev/svc.sh` 都会把该文件 `cp -an` 到工作根（已存在不覆盖）。
  - 开发态由 `dev/svc.sh` 生成宿主可用的一份（`127.0.0.1:19091`、无 TLS）并补 `admin token`；
    发布态仍是容器内 `0.0.0.0:19090` + TLS。

### 升级注意

- 现场升级后执行 `gops sys update && gops sys localize`，再 `gops run start`（`WPARSE_TAG` 变化会重建
  `wparse` 容器）—— 新 entrypoint 才会把 `wparse.local.toml` 补进 `data-plane-run/work`。
- 首次远程 infra 同步后，工作根 `conf/wparse.toml` 会变成远端模板（可能没有 `[admin_api]`），
  管理面仍由 `wparse.local.toml` 提供；若现场曾手工改过端口/TLS，请同步改到该文件。

## [0.2.0-alpha] - 2026-10-22

### 变更（**破坏性：目录布局**）

- **wparse 工程种子 `data-plane/` → `sys/data-plane/`**。它只是发布态的只读种子（挂到容器 `/seed`，
  启动时 `cp -an` 到工作根），放到 `sys/` 才符合“系统定义随包交付”；打包/交付行为不变。
- **开发态运行根独立**：`dev/svc.sh` 的工作根从 `data-plane/` 改为 `data-plane-run/dev/`，
  启动时从 `sys/data-plane/` 补缺（`cp -an`，与发布态同口径）；可用 `WPARSE_SEED` /
  `WPARSE_WORK_ROOT` 覆盖。开发态的 `data/`、`.run/` 不再落在种子目录里。
- 发布态路径不变：`sys/data-plane/` → `data-plane-run/work/`（可写运行根），运行态
  `data-plane-run/{data,.run}/` 与命名卷 `wist-gateway-stack-wparse-run` 不变。

### 升级注意

- 现场升级后执行 `gops sys update && gops sys localize`（`WPARSE_WORK_DIR` 默认值变了，`.env` 会重新生成），
  再 `gops run start` / 重建 `wparse` 容器；旧的 `data-plane/` 可删除。
- `data-plane-run/` 在 `sys-prj.yml` 的 `protect`/`ignore` 里，工作根与运行态不会被升级覆盖；
  若你手工在旧 `data-plane/{data,.run}` 里留有开发产物，需要自己挪到 `data-plane-run/dev/`。

## [0.1.55-alpha] - 2026-10-21

### 新增

- **gwlinkd 的本机组件目录（`[[upgrade.component]]`）**：`galaxy-ops` / `galaxy-flow` 声明为
  `install = "tool-copy"`（宿主二进制 `gops` / `gx`）。中心派来的这两个组件升级会**就地覆盖二进制**，
  不再落到 `gops prj upgrade <组件名>` 而以「未知系统或无效版本 spec：galaxy-ops」失败。

### 升级注意

- 该段是**模板渲染物**：`gops sys localize`（含 `gops prj upgrade` 的 regenerate 阶段）会自动重渲补齐，
  站点不需要配任何新变量。
- gwlinkd **只在启动时**读配置：升级本栈后要重启 gwlinkd（服务管理器或中心「重启 gwlinkd」），
  组件目录才生效。
- `binary` 取 `upgrader_program`（未配则 `gops`）；`gx` 按 `$HOME/bin` → `PATH` 定位，
  找不到就停在前置校验里（fail-closed，不会猜）。

## [0.1.54-alpha] - 2026-10-21

### 新增

- **`flow diagnose`（`gops run diagnose` 的系统扩展）**：一条命令就能回答“工作目录跟远端仓库到底差在哪”。
  - `wparse.work_drift`：`remote-models/models` 与 `remote-infra/{conf,topology,connectors}` 对比 `/data`，
    逐文件 sha256；区分 `only-clone` / `only-work` / `changed`，并跟上次结果比出“本次新增 / 已修复”。
  - `wparse.applied_version.{models,infra}`：`project_remote_state.json` 的 revision 与克隆 HEAD 是否一致。
  - 典型现场：发布/同步只更新了 clone、`/data` 没落到底 —— 规则静默不生效；现在一眼看出来。

### 注意

- 需要 `gops >= 2.10`（`gops run diagnose`）；老 gops 不会调用该流程，无副作用。
- **只读**：容器里只 `find` + 算 hash，不写 `/data`、不改权限、不重启。
- 豁免：`WPARSE_DRIFT_IGNORE` 或 `sys/diagnose/drift-ignore.txt` 可声明不参与全等比对的文件
  （典型：模版渲染出来的配置）。

## [0.1.53-alpha] - 2026-10-21

### 新增

- **`scripts/show-wparse-state.sh`（排障脚本）**：查看运行态命名卷里 `remote-models` / `remote-infra`
  的克隆信息（origin / state / HEAD / tag），并与工作根（`models` / `conf` / `topology` / `connectors`）
  **逐文件 sha256 比对**，直接回答「发布版本和引擎实际在跑的内容是否一致」。
  - 容器在跑走 `docker exec`（Linux 不需要 sudo 翻 `/var/lib/docker`）；容器没起时回退
    OrbStack 卷视图 / 可读的 Mountpoint，两种环境都能用。
  - `--raw` 打 `project_remote_state.json` 原文，`--logs N` 看发布日志，`--copy DIR` 把克隆导出给宿主 git / IDE。
  - 起因：`/data/.run` 是命名卷（admin token 要求 0600/属主 999），`data-plane-run/` 下看不到 git 仓库。

### 注意

- 本次**不改组件 tag**（gateway `v0.18.1-alpha` / web `v0.12.1-alpha` / wparse `0.31.1-alpha` /
  VM `v1.154.0` 均不变），升级只需替换 stack 包。
- TCR 里 `warp-parse:0.31.1-alpha` 仍未同步（本轮 `dev/push-images.sh` 推送 401：当前登录账号
  没有 `cloud/warp-parse` 的 push 权限）；只拉 TCR 的现场升级前，先用有权限的账号补推。

## [0.1.52-alpha] - 2026-10-21

### 变更

- **数据面引擎 `WPARSE_TAG` `0.30.0-alpha` → `0.31.1-alpha`**。

  升级前做过的验证（不是只看版本号）：
  - `wproj check -w <data-plane>` 全绿：Engine config、9 个 source / 24 个 sink 连接器、
    Sources 结构与 runtime、Sink targets、WPL 1/1、OML 1/1、语义词典、内网网段、wpgen；
  - 用新镜像 **真起 daemon**（同一份 `conf/wparse.toml`）并打两个管理面路径：
    `/admin/v1/runtime/status` 返回结构与 0.30 一致（`instance_id` / `version` /
    `accepting_commands` / `reloading` / `last_reload_*`）；`/admin/v1/reloads/model` 正常
    受理并回显 `X-Request-Id` —— **gwlinkd `[wparse_relay]` 的双白名单路径没变**。

  数据面工程（conf / connectors / models / topology）无需改动。

### 注意

- 升级后 `data-plane-run/work` 里的可写副本**不会**被覆盖（`cp -an` 只补缺失）。现场如果
  改过 `conf/`，新引擎的默认项不会自动生效 —— 需要时按变更点手动合。
- WarpStation 工具链（center-stack 的 `WARPPARSE_IMAGE_TAG`）已同步到 `0.31.1-alpha`，
  两边必须对齐（规则在网关上跑、在 station 里校验）。

## [0.1.51-alpha] - 2026-10-20

### 新增

- **WarpStation 规则发布链路（网关侧）**：`wparse` 管理面启用 TLS + bearer token
  （容器内 `0.0.0.0:19090`，宿主**只发布** `127.0.0.1:${WPARSE_ADMIN_PORT}`）；gwlinkd 新增
  `[wparse_relay]`，按 1.5s 短轮询 Center 命令队列，用本机 HTTPS + admin token 调 wparse，
  结果回传中心。网关仍然**不开放任何入站控制端口**。
  - 需要 **gwlinkd ≥ 0.15.0**；旧版会忽略 `[wparse_relay]`，表现为 WarpStation 设备探活超时、
    Center `gateway_commands` 一直 `pending`。
  - 路径白名单两端各自校验：只放行 `/admin/v1/runtime/status` 与 `/admin/v1/reloads/model`。
- **`wparse-run-init` + `wparse-run` 命名卷**：wparse 的 `/data/.run` 从 bind 改成命名卷。
  原因：WarpParse 要求 token 文件 `0600` 且属主=运行用户，而 `gops sys perms` 会把 bind
  文件统一成 `0660`，两者冲突。现在由 init 容器以 999 身份把宿主 seed 里的 token 复制进卷并
  `chmod 600`；宿主那份 `.host` 留给 gwlinkd 读。
- **可写运行根 `WPARSE_RUN_WORK`**：`data-plane/` 降为只读种子，启动时复制到
  `data-plane-run/work`，`[project_remote]` 才能把 Git 同步内容写进去。
- **`[project_remote]` 接入 Center Git Proxy**：`WPARSE_PROJECT_MODELS_REPO` /
  `WPARSE_PROJECT_INFRA_REPO`（Gateway 主机视角），网关不持有 CNB 凭据；
  `CENTER_DOMAIN` 用于单机部署时把 Center 域名在 wparse 容器里指回宿主网关（`extra_hosts`）。
- **`scripts/init-wparse-admin.sh`**：建可写运行根 + 生成 admin API token（缺失才生成，`0600`）。

### 变更

- `data-plane/conf/wparse.toml`：`[admin_api]` 打开（容器内非回环绑定 + TLS，证书复用网关
  admin-tls），`[project_remote]` 打开并分 models / infra 两个仓库。
- 网关页面左下角的全栈版本改读只读挂载的 `version.txt`（`WIST_GATEWAY_STACK_VERSION_FILE`），
  不再在环境变量里复制一份版本号。

## [0.1.50-alpha] - 2026-10-19

### 组件版本

- 网关 `v0.18.1-alpha`、前端 `v0.12.1-alpha`；WarpParse / VictoriaMetrics 不变。

### 变更

- 主机列表摘要带出 `maxFilesystemUsageMount`；前端列表显示「最紧张挂载点路径」，详情页磁贴
  改为「最紧张挂载点」。

## [0.1.49-alpha] - 2026-10-19

### 组件版本

- 网关 `v0.18.0-alpha`、前端 `v0.12.0-alpha`；WarpParse `0.30.0-alpha`、
  VictoriaMetrics `v1.154.0` 不变。

### 新增

- **数据面透传逐挂载点容量标签**：`agent_uplink` 的指标帧增加可选 `mount` / `fstype`，
  随网关 / 前端一起把 `system.filesystem.*` 落进 VictoriaMetrics；非文件系统指标不写空标签。
  新增回归脚本 `dev/tests/agent-uplink-metric-labels.test.sh`。

### 变更

- **web 的 resolver 缓存 `10s → 3s`**：网关重建 / 换 IP 后最多 3s 生效（`resolver 127.0.0.11 valid=3s`）。
- COS 示例桶名对齐当前对象存储：`wist-1347593047` → `github-1347593047`。

## [0.1.48-alpha] - 2026-10-18

### 组件版本

- WarpParse `0.30.0-alpha`（沿用工作区既有值；VictoriaMetrics `v1.154.0`、网关 `v0.17.0-alpha`、
  前端 `v0.11.0-alpha` 不变）。

### 修复

- **权限漂移（日志 500 / `readonly database` / 安装包无法覆盖）统一交给 `gops sys perms`**：
  它从 `docker compose config` 派生 bind 挂载，递归覆盖运行态新文件，不再靠本仓维护名单。
  现场已检出的类型：`state/install-package/{current,history}/*`、`state/logs/*.ndjson*`、
  `logs/wist-gateway.log` 为 `root:999 644`（容器只能读，写不进去）。
  `localize` 的阶段流程把它放在**最后**：`gx.download` / 初始知识库解包产生的文件也会被覆盖到。
- **备份恢复 / root 跑过的现场，网关日志写不进去**：`configs/gateway/logs/*.log`、
  `state/logs/*.ndjson*` 属主是 `root`、属组 999、模式 `644` —— 容器（uid 999）只剩属组这条路，
  append 失败后报 `log_ingest_append_failed … Permission denied`（启动时还会 `打开日志文件 … 失败`）。
  现由上面的 `gops sys perms` 覆盖。
- **网关重启时 web 连带重启循环**：web 的 nginx 原先写死 `proxy_pass https://gateway:3000`，
  upstream 只在启动时解析一次，网关没起来（或容器换 IP）就 `[emerg] host not found in upstream "gateway"`
  直接退出，`restart: unless-stopped` 于是反复拉起。现在改为 `resolver 127.0.0.11 valid=10s` +
  变量式 `proxy_pass`，运行时解析：网关短暂不在时 `/api` 回 502，web 不再重启；网关重建/IP 变化 10s 内生效。

### 变更

- **网关配置按语义拆开挂载**（compose 契约 = 真实意图）：`wist-gateway.toml`、`knowledge/` 只读；
  `state/`（store 库 / agent 日志 / 安装包与知识库副本）、`logs/`（进程日志）各自读写。
  不再把 `configs/gateway` 整目录 rw 挂到 `/config`。因此：
  - `gops sys perms`（gops ≥ 2.7）能把配置/知识库精确对齐成 `0640/2750`，而不是放宽成可写；
  - **「本地来源」不再接受 `/config/<文件名>`**：安装包统一放 `packages/`，填 `/packages/<文件名>`；
  - `wist-gateway.value.json` 不再进容器（渲染源，容器不读）。
  - `configs/gateway/` **本身不再是挂载源**：必须由 `gops sys localize` 以部署账号创建；
    **不要先 `docker compose up` 再 localize**（Docker 会以 root 建源，且缺失的 `wist-gateway.toml`
    会被建成同名目录）。
- **权限对齐统一为 `gops sys perms`**（gops ≥ 2.7，本栈硬要求）：localize 流程、
  `run start` preflight、`prj restore` / `prj upgrade` 自动 apply 均由 gops 提供；
  `sys-prj.yml` 已加 `perms:` 覆盖项说明（rootless / 根外路径）。**不再提供仓内 fallback**。

### 移除

- `scripts/align-host-perms.sh` 与 `dev/tests/align-host-perms.test.sh` 删除：
  权限逻辑由 gops 的 `sys perms` 承接（上游有自己的单测）；本栈不再维护第二套实现。
- **破坏性要求**：`gops` 必须 **≥ 2.7**（旧版没有 `sys perms`；`localize` 会直接失败并提示）。

## [0.1.47-alpha] - 2026-10-18

### 修复（组件版本）

- **WarpParse 回退 `0.30.0-alpha → 0.29.1-alpha`**：本栈暂不发布 `0.30.0-alpha`，
  数据面回到上一稳定版本；`data-plane/` 工程配置无需改动。
- VictoriaMetrics 保持 `v1.154.0`；网关 `v0.17.0-alpha`、前端 `v0.11.0-alpha` 不变。

## [0.1.46-alpha] - 2026-10-18

### 变更（组件版本）

- **WarpParse `0.29.1-alpha → 0.30.0-alpha`**：新增 OML 内联脱敏（`mask` / `hash` / `tokenize` / `remove`）
  与零配置脱敏密钥（`.warp_parse/sec_key.toml`）；随 `wp-motor 1.30.0`。**无破坏性变更**，
  `data-plane/` 的 conf / connectors / models / topology 不需要同步修改。
  镜像 tag 仍是不带 `v` 的 `0.30.0-alpha`（上游惯例）。
- **VictoriaMetrics `v1.153.0 → v1.154.0`**（常规小版本）。

### 备注

- 网关 / 前端 / gwlinkd 的版本不在本栈钉：网关 `v0.17.0-alpha`、前端 `v0.11.0-alpha` 不变，
  gwlinkd 由中心推送（当前 `0.14.0-alpha`）。

## [0.1.45-alpha] - 2026-10-18

### 变更

- **网关镜像 tag 跟进 `v0.17.0-alpha`**：gwlinkd 心跳新增 `gops_version` / `gx_version`
  （宿主侧依赖工具版本），网关落库并在「接入代理」明细里展示。

### 升级说明

- 这次是**数据可见性**变更：不改变采集 / 上报行为。页面要看到 gops / gx 版本，需要
  网关 ≥ `v0.17.0-alpha` + gwlinkd ≥ `0.14.0-alpha`（由中心推送，不在本栈内钉版本）。

## [0.1.44-alpha] - 2026-10-18

### 变更

- **网关镜像 tag 跟进 `v0.16.0-alpha`**：新增环回端点
  `POST /api/v1/gateway/knowledge-package`（中心下发知识库包的接收面）。

### 升级说明

- **知识库下发要求三层都就位**：网关 `v0.16.0-alpha` → gwlinkd `0.13.0-alpha` →
  中心 `0.16.0-alpha` / 前端 `0.9.0-alpha`。
- **旧 gwlinkd（< 0.13.0）会把 `push-knowledge-package` 当 `upgrade` 执行**，拿知识库包去跑 gops
  （报「未知系统 `wist-knowledge`」）。如果已经派过这样的计划：先把 gwlinkd 升到 0.13.0
  （它会跳过未知动作并落游标，不再每轮重试），再重派计划。

## [0.1.43-alpha] - 2026-10-18

### 变更

- **镜像 tag 跟进：网关 `v0.15.0-alpha`、前端 `v0.11.0-alpha`**。本轮：
  - 网关：新增 `POST /api/v1/admin/cos/resolve`，按 `桶/组件/版本` 前缀展开各平台制品
    （无凭据：公有读桶 + 对象元数据里的 sha256；region 未给时逐个探测，整体 60s 上限）。
  - 前端：安装包 / 知识库录入页新增「COS 路径」一键填充（与 GitHub Release 同形）；
    修复 `/gwlinkd`、`/revocations` 面包屑落到「未知页面」；补齐版式尺度 token。

### 升级说明

- 本栈内网关与前端**必须成对升**：0.11.0 的 COS 一键填充调网关 0.15.0 的新接口，
  旧网关会 404（其余功能不受影响，仅「解析」按钮报错）。

## [0.1.42-alpha] - 2026-10-18

### 变更

- **镜像 tag 跟进：网关 `v0.14.0-alpha`、前端 `v0.10.0-alpha`**。本轮：
  - 网关：采集单元明细随目录接口曝光；`match` 支持 `path_exists`（三态求值）；
    按目录里的 `path_exists` 条件推导 `probe_paths` 随发现策略下发；事实落库参与 `fact-v2` 摘要。
  - 前端：`/knowledge` 新增「采集面」全景 tab（`?view=families`），可展开看每个面具体采什么。
- **初始知识库包跟进 `wist-knowledge v0.3.0`**（`KNOWLEDGE_PATH`）：`catalog_version` 7；
  `linux-privilege-exec` 拆为 `linux-sudo-log`（`path_exists:/var/log/sudo.log` 门控）
  与 `linux-auditd-exec`（`auditd-execve` 导出器）。

### 升级说明

- **顺序固定：网关 → agentd → 知识包**。
  - 新 agentd 会多报 `probed_paths` / `present_paths`，旧网关是 `deny_unknown_fields`，会拒整份
    事实上报 —— 所以网关必须先升（`v0.14.0-alpha`）；
  - 旧 agentd 不探路径，`path_exists` 永远是「无法判定」，相关单元按 `fact_not_collected` 排除，
    所以知识包最后上（agentd ≥ 0.5.0）。
- 策略拉取有轮询节流，新增路径条件最多滞后一个周期；这段时间里对应单元显式可见为未采，
  不是静默不采。

## [0.1.41-alpha] - 2026-10-18

### 变更

- **镜像 tag 跟进：网关 `v0.13.0-alpha`、前端 `v0.9.0-alpha`**。本轮：
  - 网关：采集面词表改由知识库装载（`[[families]]`），**新增采集面不再发网关**；激活知识包时
    做追加式校验（删面 / 改名即拒，回滚除外）；`GET /api/v1/admin/content` 返回 `families`。
  - 前端：面名与说明改从内容目录取词，删除前端硬编码的 18 条文案表。
- **初始知识库包跟进 `wist-knowledge v0.2.0`**（`KNOWLEDGE_PATH`）：包内新增 18 个采集面的
  词表（ID / 平台归属 / 中英文名称与说明），`catalog_version` 6。

### 升级说明

- **必须先把网关升到 `v0.13.0-alpha`，再激活 `wist-knowledge v0.2.0`**：旧网关的目录结构是
  `deny_unknown_fields`，遇到 `[[families]]` 会拒载整包。

## [0.1.40-alpha] - 2026-10-17

### 变更

- **镜像 tag 跟进：前端 `v0.8.0-alpha`**（网关仍 `v0.12.0-alpha`）。本轮前端：
  Agent 工作页「常驻工作」卡片新增中英双语**工作名**与**说明文字**（覆盖 18 个采集面），
  原始面名仍保留在卡头，便于查日志 / 对协议值；未收录的面回落成面名本身，不编造说明。
  右上角切语言时名称与说明一起变。

## [0.1.39-alpha] - 2026-10-17

### 变更

- **镜像 tag 跟进：网关 `v0.12.0-alpha`**（前端仍 `v0.7.0-alpha`）。本轮网关侧：
  **安装命令不再要求目标机有 OpenSSL ≥ 3** —— 改用「命令内嵌的脚本 sha256」校验
  （`sha256sum`，缺失时 `shasum`），一致才执行。此前 EL7/8、Ubuntu 16.04–20.04、Debian 8–11
  一律报 `pkeyutl: Option unknown option -rawin`，agent 装不上。现在底线是「curl + systemd」的
  老发行版（Ubuntu 20.04+ / Debian 11+ / EL8+ / macOS 11+）。
- **不再生成 / 备份 / 对齐「安装脚本签名私钥」**：网关 0.12.0 移除了 `.sig` 与
  `[agent] signing_key_file`，栈侧同步：`init-gateway.sh` 不再生成
  `identity/gateway/private/install-script-signing-ed25519.pkcs8.pem`，模板去掉该键，
  `backup-gateway.sh` 与 `align-host-perms.sh` 不再引用它。

### 升级说明

- 旧部署**无需迁移**：配置里残留的 `signing_key_file` 会被新网关静默忽略；
- 磁盘上旧的 `identity/gateway/private/install-script-signing-ed25519.pkcs8.pem` 已无消费者，
  **升级到本版本后可以删除**（它属于 `identity/` 契约，留着会一直被收进 contract 导出）；
- 已发出的旧安装命令（若还留着）会因摘要不匹配而拒跑 —— 重新复制一次命令即可。

## [0.1.38-alpha] - 2026-10-16

### 修复

- **Linux 上网关因读不到栈根密钥文件而无限重启**：`.wist/sec-value.yml`（网关 admin token 的来源）
  由 `scripts/init-gateway.sh` 以 `600` 生成，而网关容器固定以 `999:999` 运行 —— 属主是部署账号或
  root 时容器读不到，网关以 `failed to load secrets /secrets/sec-value.yml: system error` 反复退出
  （前端随后报 `host not found in upstream "gateway"`，它只是被拖累）。现在 `gops sys localize` 会把
  `.wist/`（2755）与 `.wist/sec-value.yml`（640）一并纳入宿主权限对齐，与 `configs/`、`identity/`
  同一套口径。**已部署的宿主机升级后跑一次 `gops sys localize`（或栈根 `scripts/align-host-perms.sh`）
  即可恢复**；macOS 因 bind 挂载不校验属主，没有这个问题。

## [0.1.37-alpha] - 2026-10-16

### 变更

- **镜像 tag 跟进**：网关 `v0.11.0-alpha`（前端仍 `v0.7.0-alpha`）。
  本轮带来：**容器部署下宿主侧常驻（`wist-gwlinkd`）连不上网关**的修复 —— 网关在容器里时，
  本机环回面（自述面 / 接入请求 / gwlinkd 心跳 / agent 包下发）曾把宿主自己的连接当成「外来」
  而一律 403（表现为 `journalctl -u wist-gwlinkd` 每 30s 一对 `LinkRequestFailed` /
  `LinkdStatusPushFailed`、网关页报「未检测到 gwlinkd 心跳」）；现在会把**容器所在网络的网关**
  （= 宿主在该网络上的地址）也认作本机，**外部客户端仍被拒**。另新增 `[server] self_face_allow`
  （非标准网络兜底；`/0` 拒启）。排查入口：网关启动日志 `event=LocalHostPeers …`。

## [0.1.36-alpha] - 2026-10-15

### 变更

- **初始知识库包 `KNOWLEDGE_PATH` 跟进到 `v0.1.6`**（原 `v0.1.4`）：pin 不再落后于最新的已发布制品，
  内网 / 镜像源可按同一 tag 对齐取件。**内容与 `v0.1.4` 相同** —— `v0.1.5` / `v0.1.6` 只动了发布侧
  （制品推 COS + 自带 sha256），知识内容本身没变（验签公钥也是同一把）。

## [0.1.35-alpha] - 2026-10-15

### 变更

- **镜像 tag 跟进**：网关 `v0.10.0-alpha`、前端 `v0.7.0-alpha`。
  本轮带来：网关侧**安装脚本支持「重装（替换客户端证书）」**（`WIST_AGENTD_REINSTALL=1`，用于证书已过期 /
  换过网关 / 本机身份错乱）、装错平台立刻拒绝、总览「最近上线注册 Agent」不再硬截到 6 张；
  前端侧**新增浅色主题**（默认仍深色）、管理令牌入口挪到右上角状态条、数据采集页与总览的可读性调整。

## [0.1.34-alpha] - 2026-10-15

### 新增

- **`dev/install-gwlinkd-dev.sh`：把本机编译的 gwlinkd 发布到已装的系统服务**（开发机自用）——
  构建 → 备份旧二进制 → 换上 → 重写服务定义并重启 → 验证；带 `--dry-run` / `--status` / `--rollback`。
- **`dev/gwlinkd.sh`：在服务那份配置上跑 gwlinkd 子命令**（`diagnose` / `service status` …）——
  bin / 主配置 / 现场态都从已装的服务定义里读，不必再敲那几串长路径；`--paths` 只看落点。

### 变更

- **gwlinkd 不再由 `dev/svc.sh` 管**：不构建、不起、不停、不看（组件、`--no-gwlinkd` 与相关变量 / 函数
  全部移除）。宿主侧常驻改由**系统服务**托管 —— 发布态仍由中心下发的安装脚本装，开发态装/更新/回滚走
  `dev/install-gwlinkd-dev.sh`。
- **`dev/unlink-center.sh` 改为「服务感知」**：停 / 起走服务管理器（`launchctl` / `systemctl`），
  bin / 主配置 / 现场态从服务定义读 —— 清的是**服务那一份**注册态，不再猜。
- **gwlinkd 现场态变量名统一为 `GWLINKD_*`**（`CENTER_ENDPOINT` → `GWLINKD_CENTER_ENDPOINT`、
  `TRUST_BUNDLE` → `GWLINKD_TRUST_BUNDLE`；`GWLINKD_GATEWAY_ID` 原本就带前缀）：与 gwlinkd 仓骨架同一套名，
  避免「值写在一个名下、声明引用另一个名」的死键（最坑的是 `TRUST_BUNDLE=` 空着 —— 看着像信任锚没配，
  实际生效的是 `GWLINKD_TRUST_BUNDLE`）。初始化脚本还会按**声明里引用的 `${VAR}`**
  清掉未被引用的死键（读不到声明就不清，防清空）。

### 升级注意

- **已有现场：`.env` 里旧键的值要先搬到新键**（`CENTER_ENDPOINT` → `GWLINKD_CENTER_ENDPOINT`、
  `TRUST_BUNDLE` → `GWLINKD_TRUST_BUNDLE`），再跑 `gops sys localize` —— 重渲会把未被声明引用的旧键
  **自动清掉**，值不会跟着搬（中心地址 / 信任锚会变空 → 网关侧显示「未接入」）。
- **gwlinkd 宿主侧常驻改由系统服务托管**：发布态由中心下发的安装脚本装（无需额外动作）；开发态用
  `./dev/install-gwlinkd-dev.sh`。`svc.sh` 不再带 gwlinkd —— `./dev/svc.sh status` 也不会再列它。
  macOS 上带 `--run-as` 的服务需 `wist-gwlinkd >= 0.10.0-alpha`（修了日志目录属主）。

## [0.1.33-alpha] - 2026-10-14

### 变更

- **制品推送到 COS 时自带 sha256**：上传的每个对象带自定义元数据 `x-cos-meta-artifact-sha256`
  （COS 只存 MD5 ETag，GitHub 资产摘要过不来）；可用 `coscli stat`（HEAD）读回。`x-cos-meta-`
  是 COS 对自定义元数据的强制前缀。

## [0.1.32-alpha] - 2026-10-14

### 变更

- **镜像源可各自指定，不再一刀切**：镜像源前缀由单个 `IMAGE_SPC` 拆成三个 —— `WIST_SPC`（网关 / 前端）、
  `WARP_SPC`（wparse）、`VM_SPC`（VictoriaMetrics），可分别指向不同 registry，在 `values/value.yml`
  覆盖后 `gops sys localize` 生效。**破坏性**：旧变量名 `IMAGE_SPC` / `WPARSE_IMAGE` 不再识别，
  现场用旧名的覆盖需改名（`IMAGE_SPC` → `WIST_SPC`，`WPARSE_IMAGE` → `WARP_SPC`）。
- **VictoriaMetrics 默认源改为 `quay.io/victoriametrics`**：避开 Docker Hub 匿名拉取限流
  （`429 Too Many Requests`），现场 / CI 拉取更稳。
- **数据面引擎升级到 wparse `0.29.1-alpha`**（`WPARSE_TAG`）。

### 新增

- **`dev/push-images.sh`：把上游镜像同步到 TCR**：把发布态 compose 里**非 wist\*** 的镜像
  （VictoriaMetrics / wparse）推到指定 registry（默认 `dy-sec.tencentcloudcr.com/cloud`），供内网 /
  客户环境统一从 TCR 拉取。推前先探目标（已存在且 digest 一致则跳过）、做登录预检；推完自动 inspect
  校验 digest 落地。用法见 `dev/README.md`。

## [0.1.31-alpha] - 2026-10-13

### 变更

- **初始知识库包地址拆成两段，便于整段替换制品源**：`KNOWLEDGE_PKG_URL` 拆为 `ARTIFACT_HOME`
  （制品基址）+ `KNOWLEDGE_PATH`（相对路径，带版本）。换内网 / 镜像源时只需改 `ARTIFACT_HOME`
  并写对应的 `KNOWLEDGE_PATH`，不用再维护一整条 URL；任一为空即跳过初始知识库包。

### 移除

- **仓内不再携带现场站点值**：删除 `values/value.yml`；现场覆盖（如 `WEB_DOMAIN`）改在
  `values/sys_value.yml` 里改（该文件不入库）。

## [0.1.30-alpha] - 2026-10-13

### 变更

- **发布时可选把制品推送到腾讯云 COS**：打 tag 时新增 `upload-cos` job，把
  `wist-gateway-stack-<tag>.tar.gz` 上传到 `cos://<桶>/wist-gateway-stack/<tag>/` 与
  `.../latest/`（未配置 `COS_BUCKET` 时自动跳过，不影响发布）。

## [0.1.29-alpha] - 2026-10-13

### 变更

- **内部依赖包跟进：网关镜像 `GATEWAY_TAG` → `v0.9.1-alpha`**（对应 `wist-gateway` `v0.9.1-alpha`：
  分层配置读取改用共享 `wist-config`）。

## [0.1.28-alpha] - 2026-10-13

### 变更

- **gwlinkd 配置分层：主配置（交付物）+ 现场态 `identity/gwlinkd/pub.toml`**（需 `wist-gwlinkd >= 0.9.0`）：
  - 主配置 `configs/gwlinkd/gwlinkd.toml` 只由模板渲染**交付物类**项（运行态目录 / 环回自述面 /
    投放目录 / 升级参数）—— 升级 / 重渲该覆盖；
  - **现场选择**（上级中心地址 / 本网关在中心侧的标识 / 中心信任锚）与一次性券 `link_token`
    移到 `identity/gwlinkd/pub.env`：**形态就是 `.env`**（`KEY=VALUE`，键名 = 配置键名大写；
    `CONTROL_CENTER_ENDPOINT` / `GATEWAY_ID` / `TRUST_BUNDLE`）—— 现场值本就来自环境变量,
    所以**不要模板、不要占位符替换、不产生中间渲染物**；
    `scripts/init-gwlinkd-pub.sh` 只做一件事：按缺（**键不存在或值为空**）把几个键写进去，
    非空一律保留（现场改过 / 页面写过 / 迁移搬来的）。gwlinkd 加载时读**两份**（叶子键不许重复）。
    因为落在 `identity/` 之下，它随既有的 `contract: - identity` **自动**获得“不进包 / 不重渲 /
    必进备份” —— `sys-prj.yml` **无需改动**。
    升级时：把旧的 `identity/gwlinkd/pub.toml` 改成 `pub.env`（键名大写）即可，
    gwlinkd 两种写法都读（键名大小写不敏感、值引号可选）。
- **gwlinkd 身份与运行态分开**：新增变量 `GWLINKD_IDENTITY_DIR`（默认 `./identity/gwlinkd`）——
  不可再生的身份材料（客户端证书 + 私钥、中心信任锚）落这里（进 contract）；
  `GWLINKD_STATE_DIR`（默认 `./configs/gwlinkd/state`）只剩单实例锁 / 升级簿记 / 临时注册券。
  中心 CA 的路径由 `GWLINKD_TRUST_BUNDLE` 改为 `./identity/gwlinkd/control-center.pem`。
- **dev 态与发布态共用一份身份 / 现场态**（与网关的 `identity/` 同口径）：
  `dev/svc.sh` 启 gwlinkd 时注入 `WIST_GWLINKD_PUB_CONFIG=<栈根>/identity/gwlinkd/pub.toml`，
  并幂等补 `identity_dir`；`dev/unlink-center.sh` 同步。

### 升级注意

- 已有现场需跑一次 `gops sys localize` 补出 `identity/gwlinkd/pub.toml`。
- **必须重装宿主服务**（否则进程拿不到 `WIST_GWLINKD_PUB_CONFIG`，会报“未接入上级”）：
  `wist-gwlinkd service install --system --run-as <用户> --bin … --config …/configs/gwlinkd/gwlinkd.toml --pub-config …/identity/gwlinkd/pub.toml --force`
  （重跑中心下发的安装脚本即可）。
- 老现场的 `configs/gwlinkd/control-center.pem` 与 `configs/gwlinkd/state/credential.json`
  需搬到 `identity/gwlinkd/` 下（**先备份**），否则会被当成“尚未接入” —— 而中心无“重置实例”接口，
  丢了身份只能**新建实例、换 `gateway_id`**。

## [0.1.27-alpha] - 2026-10-12

### 变更

- **镜像 tag 跟进**：网关 `v0.9.0-alpha`（新增**接口层配置** `wist-gateway-pub.toml` 支持 —— 本栈配置拆两层依赖它；
  并新增公开 `GET /api/v1/version` 供页面显示后端版本）。前端 `v0.6.0-alpha`（左下角新增前后端版本块；
  前端版本 = 发布 tag 注入，后端版本读同一公开端点）。
- **身份与资源分离：站点身份（CA / 证书 / 私钥 / 对外域名）提到栈根 `identity/`，dev 与发布态共用一份**：
  - 以前证书/私钥与 store 混在 `configs/gateway/state/`；现在：
    - `identity/gateway/{public,private}/` —— 证书（公开）/ 私钥（私密）+ `wist-gateway-pub.toml`（对外域名 / 归属）；
    - `identity/web/{public,private}/` —— 前端站点证书 / 私钥；
    - `configs/gateway/state/` —— **只剩**每部署一份的 store 库。
  - 好处：资源树（`configs` / `dev/configs`）在 `sys-prj.yml` 里可**整目录**声明；身份独立且**整体**（含私钥）作 `contract`——可 `gops prj contract export/import`；
    身份不再各态一份 —— 避免 dev / 发布态各建一套 CA、agent 信任分叉。
  - **`sys-prj.yml: contract` = 整个 `identity/`（含私钥）**：身份是「证书 + 私钥」一对，**只留公开半不自足**（丢私钥 = 签不出新叶/客户端证书 = 换锚），
    故让 `contract export` 的归档**独立复原站点身份**。代价：该归档**含私钥 → 按密件处理**（落点要安全 / 离机）。
  - 网关容器多挂一个只读卷 `identity/gateway → /config/identity`，tpl 里证书路径改 `identity/public|private/...`；
    web 容器挂 `identity/web → /certs`（nginx 走 `/certs/public|private/...`）。
  - **升级 / 迁移注意**：老现场的 `configs/gateway/state/*.pem`、`configs/web/tls/*` 需搬到 `identity/` 下对应的 `public|private`
    子目录；dev 侧 `dev/configs/gateway/identity` 改为指向栈根共享身份的 symlink、`wist-gateway-pub.toml` 同样 symlink。**搬前先备份。**
    另：若 `dev/configs/gwlinkd/gwlinkd.toml` / 现场 `gwlinkd` 配置里的 `gateway_self_ca` 仍指旧的
    `…/configs/gateway/state/gateway-ca.crt.pem`（身份已不在那里），改成 `identity/gateway/public/gateway-ca.crt.pem`
    —— 否则 gwlinkd 启动即报「读取信任锚失败」。
  - `scripts/promote-dev-identity.sh` **移除**：身份已共用，无需再从 dev 搬身份（要搬 dev 的 store 库，直接拷 `state/`）。
- **网关配置拆两层：`wist-gateway.toml`（impl，交付物）+ `wist-gateway-pub.toml`（接口层，现场态）**：
  “这台网关**对外是什么**”的三个键（`public_base_url` / `tenant_id` / `environment_id`）**移出**主配置模板，
  改由新增的 `scripts/init-gateway-pub.sh` 写到同目录的 `wist-gateway-pub.toml`（localize 里的 ①'' 步）。
  该脚本**按缺补齐、已有值一律保留**（可每次 localize 跑，**永不覆盖现场值**）。
  网关加载时读**两份**（段可重合、**叶子键不许重复**；见 wist-gateway 的 `load_from_path`）。
  好处：主配置成了**纯渲染物**（升级/重渲可覆盖），对外基址与归属有了**唯一对象** —— `wist-gateway-pub.toml`
  随之声明进 `sys-prj.yml: contract`（对外契约，见下条；主配置 `wist-gateway.toml` 是渲染物，不入备份）。
  **升级注意**：已有现场需跑一次 `gops sys localize`（或单独跑该脚本）补出 `wist-gateway-pub.toml`，
  否则网关会以“缺 `public_base_url`”拒绝启动。dev 侧配置不走这条（仍是单文件），不受影响。
- **`sys-prj.yml` 跟进 gops 2.3.0**：`preserve:` 更名为 `protect:`；`backup:` 由分级 `{restore, rebuild}`
  改为**扁平列表**（`packages` 属可重投的“可重建”，不再入表）；新增 `contract:` 声明**不可重建的公开现场事实**：
  `wist-gateway-pub.toml`（对外域名）+ `configs/gateway/state/*.crt.pem`（与 agentd 的信任契约：
  `gateway-ca.crt.pem` 是 agent 的信任锚、`agent-ca.crt.pem` 是给 agent 签客户端证书的根）+ `*.pub.pem`
  （公开验签公钥）+ `configs/web/tls/*.crt.pem`（前端/浏览器的公开证书）。
  语义自足（声明即自动 `protect` + `backup`），可 `gops prj contract export/import`
  单独做**可公开携带**的归档。**私钥**（`*.key.pem` / `*.pkcs8.pem`）是私密身份，只走 `backup`，**绝不进 `contract`**。
  注意：`contract` 路径**不与 `ignore`/`protect` 交叠**，故 `configs/`、`configs/gateway/state`、`configs/web`
  由“整目录”改为**逐项列出**（私钥材料仍逐条被挡，`--full` 护栏不降级）。`gops prj diagnose` 全绿。
- **网关配置模板键名精简**：`sys/configs/gateway/wist-gateway.toml.tpl` 的 `[agent]` 段改名为
  `ca_cert_file` / `ca_key_file` / `bootstrap_ttl_seconds` / `signing_key_file`
  （与网关新版配置结构同口径）；`scripts/init-gateway.sh` 注释同步。
- **网关模板补 `[log]`（本进程运行日志）**：模板原先未暴露该段；现给出**活跃**的 `[log]`
  （`level` / `format` + `file` 与轮转），落文件到已挂载持久化的 `<config>/logs/wist-gateway.log`。
  注意：网关给了 `file` 就不写 stderr（打开失败才回落 stderr）—— 需要 `docker logs` 看网关自身日志就别配 `file`。
- **管理 token 从配置里拆出，走密钥文件**：模板的 `admin_api_token` 不再渲染明文，改写
  `${SEC_ADMIN_TOKEN}`；token 落**栈根 `.wist/sec-value.yml`**（键 `admin_token`，`scripts/init-gateway.sh`
  缺则生成），compose 把该文件只读挂进容器并 `WIST_GATEWAY_SEC_FILE=/secrets/sec-value.yml`，
  网关加载时解析。`.wist/` 已 `.gitignore`。（网关侧见 wist-gateway 的 orion-sec 接入。）

## [0.1.26-alpha] - 2026-10-07

### 变更

- **镜像 tag 跟进**：网关 `v0.3.0-alpha`、前端 `v0.2.0-alpha`。
- 本轮带来：网关侧**主机指标带上机器身份**（`node_id` / `hostname` / `ip_addresses`，由网关 join 注册表
  补齐，不往指标标签里塞）；安装包 / 知识库包摘要改为必填。前端主机指标页显示主机名与主地址
  （多网卡不再铺十几条 IPv6 链路本地地址）。

## [0.1.25-alpha] - 2026-10-05

### 变更

- **镜像 tag 跟进**：网关 `v0.1.19-alpha`、前端 `v0.1.15-alpha`。
- 本轮网关侧带来：自述面富化（进程 / 机队 / 存储 / 数据面 / 主机资源）、gwlinkd 状态通道、
  接入请求 CA 按 scheme 条件必需；依赖版本对齐（`wist-control` 0.6 / `wist-contracts` 0.2）。
  前端「链接上级」接入状态置顶 + gwlinkd 状态 / 中心地址展示。

## [0.1.24-alpha] - 2026-10-05

### 变更

- **开发态网关 home 迁到仓库内**：`./dev/svc.sh start gateway` 的默认 home 从 `~/.wist-gateway`
  改为 `<栈根>/dev/configs/gateway`（对称发布态 `configs/gateway`，且 `.gitignore` 忽略）——
  不必再记「配置在哪个家目录」。已有 `~/.wist-gateway` 的机器把该目录搬到 `dev/configs/gateway` 即可，
  agent 注册表随库一起走、无需重装。
- 新增 `./dev/svc.sh token`：打印**开发态**网关的 admin token 与出处（只认开发态 home），
  避免与发布态 `configs/gateway/wist-gateway.toml` 的同名配置混拿。

## [0.1.23-alpha] - 2026-10-03

### 变更

- **镜像 tag 跟进**：网关 `v0.1.15-alpha`、前端 `v0.1.13-alpha`。
- **管理面能认出「这是哪台机器」**：机队页新增 IP 列，Agent 工作页头部显示**主机名 · IP**。
  此前凭客户端证书首触注册的机器只剩一个 ID —— 现在由 agent 的状态上报补上机器画像
  （配套 agentd `v0.1.24-alpha`，契约 `wist-contracts` 0.1.14）。

### 升级注意

- **先布新网关、再布新 agentd**：状态上报契约新增了字段，旧网关会拒收带新字段的上报。
  顺序：`gops sys download`（拉新镜像）→ `gops sys start` → 再把 agent 升到 `v0.1.24-alpha`。
- **页面显示主机名 / IP 需要 agentd `v0.1.24-alpha`**：仍停在 `v0.1.23` 的机器不发机器画像，
  升到 0.1.24 后下一次状态上报（≤3s）即补齐。

## [0.1.22-alpha] - 2026-10-03

### 变更

- **镜像 tag 跟进**：网关 `v0.1.14-alpha`、前端 `v0.1.12-alpha`。
- **初始知识库包抬到 `v0.1.4`**：LinuxHost 现在有 10 个采集面可采（新增 4 个「导出器」面：
  服务生命周期 / 崩溃与 panic / 网络与防火墙 / 关机重启，外加存储健康）。
- 配套 agentd `v0.1.22-alpha` 新增**定时导出器**能力（journald / `last` / `smartctl` / `nft` /
  `iptables-save` / `dmesg` / `auditd`）：导出器**跑前预检工具是否存在**，缺失记入
  `state/exporters.json` 并由 `wist-agentd diagnose` 报出（装 `smartmontools` 等即自动恢复）。

### 升级注意

- **先布新网关与新 agentd，再上知识包**：旧网关会把新目录里 `active` 的 `Exporter` 单元判成
  「不可采」而不装载。顺序：`gops sys download`（拉新镜像）→ `gops sys start` → 布 agentd
  `v0.1.22-alpha` → `gops sys localize`（拉 v0.1.4 知识包）→ 重启网关。
- 升完给那台 LinuxHost **重新授权**（旧授权锁在旧 `catalog_version`，只会带旧面）。
- 存储健康面需目标机装 `smartmontools`（否则该面采不到，`diagnose` 会报缺件）。

## [0.1.21-alpha] - 2026-10-02

### 变更

- **镜像 tag 跟进**：网关 `v0.1.13-alpha`、前端 `v0.1.11-alpha`。
- **出厂初始知识库包跟进 `wist-knowledge v0.1.2`**：里面多了「通用 Linux 服务器」类别 `LinuxHost`
  与 Linux 侧第一个能真正派下去的采集面（主机指标）。普通 Linux 机器由此**第一次**有用途建议可采纳、
  并且能派出一份常驻工作 —— 以前它在网关里既没有可采纳的建议，也没有任何采集就绪的面。

### 修复

- **`gops sys localize` 的初始知识库步骤不再静默跳过**：`KNOWLEDGE_PKG_URL` 为空时会**显式告警**
  并说清后果（网关将空载：不产用途建议、也派不出活）；设了地址但包没落盘时**直接失败**，报错点明
  「多半是这台机器不可达（外网 / GitHub 被墙）」并给出手工放包或换可达镜像的处置。
  以前这两种情况都只留下一句轻描淡写的「跳过」，装出来的网关看起来正常、实际什么都不采。
  新增回归测试 `dev/tests/install-initial-knowledge.test.sh`（纯本地、不需要 docker）。

## [0.1.20-alpha] - 2026-10-02

### 修复

- **用备份在新机器重建后网关起不来（SQLite 打不开库）**：`--level restore` 备份里带的
  `wist-gateway-store.db` 是**部署账号**解出来的（属主/属组都不是容器身份）→ 容器只能读不能写，
  网关报 `unable to open database file` / `readonly database` 后反复重启。
  现在 `align-host-perms.sh` 会把「不是容器身份建的」库放开到属组可写（`660`，属组=容器 gid）；
  容器自己建的库（`999:999`）**不碰** —— 否则每次 `localize` 都要提权。
- 顺带把 `state/*.srl`（CA 序列号文件）也归到部署账号：它由宿主 `openssl` 在重新签叶时写入，
  一旦曾被 root 跑过就会卡住后续非 root 的签叶（同一类「谁先创建就归谁」的残留）。

## [0.1.19-alpha] - 2026-10-02

### 修复

- **全新 Linux 主机上的部署不再需要手工 `chown`** —— 修掉两个「干净机器必踩、容器无限重启」的阻断：
  - 数据面：`flock: cannot open lock file /data/.run/.wparse.lock: Permission denied`（容器以 75 退出、反复重启）；
  - 网关：`failed to read install script signing key …: Permission denied (os error 13)`。

  根因相同：业务镜像固定以 `999:999` 运行，而 Linux 的 bind 挂载**不改属主** —— 目录/私钥归「谁先创建就归谁」
  （`docker compose up` 会先把缺失的挂载源目录建成 `root:root`），容器于是写不了、读不到。
  现在由 `scripts/align-host-perms.sh` 在 `gops sys localize` 里自动对齐：
  **属主 = 部署账号、属组 = 容器 gid、挂载目录 2770(setgid)、私钥与含 token 的 `wist-gateway.toml` 为 640**。
  由此：容器读写自如，**备份/恢复仍以部署账号身份工作（不需要提权）**，其它宿主账号连目录都进不去；
  对齐是幂等的（已对齐就不写盘、不要权限），非 Linux 自动跳过。

### 变更

- `gateway` / `wparse` 的**运行身份显式钉死**为 `user: "999:999"`（不再依赖镜像声明的用户 —— 镜像重建
  换了 uid，宿主侧按 999 对齐的目录就会错位，而症状只是「容器无限重启」）。
- 端口注释与实际编排对齐（原来写 `3000:3000` / `8443:80`，实际是变量宿主端口 + 容器内 `3000`/`443`）。
- 文档里的运行时命令改成 gops 2.x 的正确写法（`gops sys start|stop|…` → `gops run …`，2.0.4 起已拆分），
  并补上「前置：Docker + Compose V2 + 执行账号在 docker 组」与「权限与运行身份」两节。

### 其它

- 去掉 wparse 知识库配置注释示例里的 `${SEC_PWD}`：引擎对**整份文本**做变量替换（注释也算），
  会白打 `vars not value: SEC_PWD` 的噪音。
- 新增 `dev/tests/align-host-perms.test.sh`：在一次 Linux 容器里回归宿主属主/权限语义（27 项断言，
  `docker` 即可跑；开发机多是 macOS，那里验证不了这类内核行为）。

## [0.1.18-alpha] - 2026-10-02

### 修复

- **Debian/Ubuntu 上 `gops sys localize` 会在渲染前端站点配置时中断**（`gx.tpl` 报
  `parse json data file`，或上下文里带 `need-fmt: json`），于是 `configs/web/nginx.conf` 不生成、
  `gops sys start` 起不来 web 容器；同样的操作在 macOS 上却一切正常 —— 典型「本机好好的、上云才炸」。
  原因是那份渲染值由一行内联命令拼装，在 Ubuntu（`/bin/sh` 是 dash）会写出非法 JSON。
  现在改由 `scripts/init-web-conf.sh` 生成，两种系统产物一致。
- 附带收益：`WEB_DOMAIN` 为空或含非法字符时**当场明确报错**（旧行为是安静地写出一个坏值，
  把问题推到下一步）；域名没变时重复 `gops sys localize` **不再改动该文件**。

## [0.1.17-alpha] - 2026-10-01

### 新增

- **升级 / 备份 / 还原改成“声明式”，不再靠现场手写脚本**（配合 gops `prj update` / `prj backup` / `prj restore`）：
  `sys-prj.yml` 补上两节——
  - `preserve:` 现场态（`.env` / `configs` / `packages` / `data-plane-run` / `dev/bin`）：升级**不覆盖、也不删**；
  - `backup.restore:` 丢了要重装/换身份的那几样（网关 CA 与 admin TLS 私钥、安装脚本签名私钥、
    网关 store 库、`wist-gateway.toml` / `wist-gateway.value.json`、web CA），`backup.rebuild:` 只收 `packages`。

  现场价值：换版本用 `gops prj update`（包内覆盖、身份材料与运行态不碰）；备份与还原用
  `gops prj backup` / `prj restore`，含清单 + sha256 并点名私钥。`configs/gateway/state/logs/`（约 11 GB/天）
  与 `data-plane-run/` **不在任何备份档**：不收、不碰。

### 变更

- **前端镜像跟进 `v0.1.10-alpha`**（取数失败优先透出服务端正文，不再一律说“服务未启动”）。

## [0.1.16-alpha] - 2026-10-01

### 变更

- **前端页面的证书改成「CA + 由它签的叶」**（原来是一张自签叶）。自签叶不能被当作 CA 信任，
  浏览器只给“按站点例外”——而例外按证书绑定，**证书一换（换域名 / 到期重签 / 重建 configs）
  就失效**，于是又弹一次安全警告。改后只需把 **CA 导入一次**，之后它签的叶浏览器自动接受，
  换叶零动作。`gops sys localize` 会打印该导入哪一份 CA（路径 + 指纹）。
  - 新文件：`configs/web/tls/web-ca.crt.pem`（导入浏览器的那张）与 `web-ca.key.pem`
    （0600，只在本机保管；**丢了 = 换锚 = 每台浏览器都要重新导入**）。
  - 幂等：CA **只建一次、绝不重生成**；叶仅在「缺失 / 与当前 CA 不对应 / SAN 缺当前域名」时重签。
  - 可用 `WEB_CA_CRT` / `WEB_CA_KEY` 复用**外部 CA**（已有 CA，或 KMS/HSM 导出的）。
  - 同时修掉一个潜伏问题：以前 localize 用 `test -f web-tls.crt.pem || …` 短路，
    **改了 `WEB_DOMAIN` 不会重签**（叶的 SAN 里一直没有新域名，浏览器报域名不匹配）；
    现在由脚本自己判断，换域名会正确重签。

## [0.1.15-alpha] - 2026-10-01

### 修复

- **交付出去的栈不再“验签默默关闭”**。知识库内容包的验签公钥以前只从“同级 wist-knowledge 仓”找，
  而交付物里**没有**同级仓 —— 于是现场跑 `localize` 永远找不到公钥，网关静默变成不验签（只记
  sha256）。现在公钥**随栈入库**（`sys/keys/knowledge-signing.pub.pem`），localize 就地取材；
  `KNOWLEDGE_SIGNING_PUBKEY` 仍可覆盖（现场换键），同级仓那份留作开发便利。
  随包的那把与发布制品对过：摘要一致 + Ed25519 验签通过（指纹 `502d6b90…`），
  且 localize 会打印**来源与指纹** —— 换错/漂移一眼可见。
- **本地 `gops sys package --full` 不再可能把身份材料打进去**：`sys-prj.yml` 加 `ignore:` ——
  `configs/`（现场生成的 CA / TLS / 安装脚本签名**私钥**与 store 库）、`data-plane-run/`
  （引擎运行态）、`dev/bin/`（~92M 本地二进制）。默认模式本来就只收 git 入库文件，这条是护栏；
  CI 的交付包走 `git archive`，不受影响。

## [0.1.14-alpha] - 2026-10-01

### 新增

- **出厂自带一个初始知识库内容包，装上就有内容**。`gops sys localize` 会从 `wist-knowledge`
  的发布制品拉一份包（`KNOWLEDGE_PKG_URL`）并解开到网关了 **启动期知识源**目录；网关在
  管理面还没激活过任何包时就直接用它。以前新装/重置库后网关是“空载”的（不产系统类型建议、
  不产用途建议），要人工去「知识库」页录入一次；现在不必。管理面一旦切了可用的包，包就接管。
  离线/不需要时把 `KNOWLEDGE_PKG_URL` 置空即可跳过（`values/value.yml` 里改，不用动模板）。
- 包**升级**只需改 `KNOWLEDGE_PKG_URL` 里的版本 —— 文件名随版本变，不会复用上一版；
  解开时目录先清空再解，不会留旧文件。

### 变更

- **镜像 tag 跟进**：网关 `v0.1.12-alpha`（知识库来源改为按优先级解析、坏包不再阻止启动、
  新增 `[knowledge] source_dir` 与启动来源日志）、前端 `v0.1.9-alpha`（「知识库」页把
  “出厂初始包”与“过渡态”分开说）。
- `[knowledge]` 段从“配了验签公钥才渲染”改为**总是渲染**，同时给出 `source_dir`；
  两者各管一头，都不配也不会出错。

## [0.1.13-alpha] - 2026-10-01

### 变更

- **镜像 tag 跟进**：网关 `v0.1.11-alpha`（新增数据面上送的**部署级启用开关**）、
  前端 `v0.1.8-alpha`（开放该开关与上送地址的录入）。两者都是给“新装的机器什么也干不了”
  那个问题的：现在不必先逐台派工，网关侧一开关就能让所有 Agent 开始上送。
- **单实例保障（发布态）**：`docker-compose.yml` 给四个服务钉上**固定 `container_name`**。
  默认名字里带**项目名**（默认取目录名），两份同名目录的栈会共用同一批容器名 —— 第二个 `up`
  不报错，而是静默接管第一个的容器（“停了却还在跑”就是这么来的）。钉死后第二个栈当场报名字冲突。
  这是“一个操作系统上只允许一套本栈”的发布态那一半（容器内还有网关自己的锁）。
- **网关查询观测后端的地址参数化**（`VICTORIA_METRICS_URL`）：默认仍是容器服务名
  `http://victoria-metrics:8428`；网关跑在**宿主**的开发态需在 `values/` 里覆盖成宿主可达地址，
  否则「数据采集」页会 502（宿主进程解析不到 compose 服务名），而地址其实配得好好的。
- **开发态脚本整理**（`dev/`）：网关跑在宿主时补上“443 → 网关端口”的那一跳转发
  （发布态由 docker 提供），`agentd` 按默认端口即可连上；本地开发说明同步更新。

### 修复

- **`scripts/init-knowledge-signing.sh` 缺少可执行位**：`gops sys localize` 会以
  `Permission denied（exit 126）` 当场失败，从而**整套配置生成都跑不下去**（v0.1.12-alpha 起的
  问题）。已补上可执行位，并实测 `gops sys localize` 从头到底通过。

## [0.1.12-alpha] - 2026-09-29

### 变更

- **启用 agent 客户端证书（mTLS）**：`scripts/init-gateway.sh` 现在会生成一把**独立的 agent CA**
  （`state/agent-ca.crt.pem` / `agent-ca.key.pem`，`CN=Wist Agent CA`），网关配置模板声明
  `agent.agent_ca_cert_file` / `agent_ca_key_file`。效果：**新装/重装的 Agent 注册时即用本地 CSR
  换到客户端证书**，于是**网关换库/丢库后 agent 能自动重建身份**（网关按证书重建登记）—— 否则只能
  人工逐个重新注册。agent CA 与网关 CA 分开两把，且都会随 `backup-gateway.sh` /`restore-gateway.sh` /
  `promote-dev-identity.sh` 一并带走（同一份身份材料）。
- 镜像顶版：网关 **`v0.1.9-alpha`**（新装 Agent 的注册材料改申请客户端证书）。
- 宿主端口：网关对外端口由 3000 改为 **443**（`GATEWAY_PORT`）。

### 升级注意

- 首次 `gops sys localize` 会新建 agent CA（已存在则复用，**绝不重生成**）——它必须与网关 CA **一起备份**；
  丢了 = 之后丢库的 agent 无法自动重建。
- 已在跑的 bearer-only Agent 不会追溯获得证书，需要重新注册（`wist-agentd enroll --force --token <t>`）一次。
- `GATEWAY_TAG` 已指到 `v0.1.9-alpha`：先 `gops sys download` 再 `gops sys start`。

## [0.1.11-alpha] - 2026-09-29

### 变更

- `.gitignore`：把 `gops sys package` 生成的 **交付锁 `deliver.lock`** 纳入忽略。它是每次打包重生的记录
  （version + generated_at + merged_vars/values 的哈希），而且 package 会自己把它塞进交付包里 ——
  入库只会多一份“写着旧版本号 + 旧哈希”的会漂移文件。

## [0.1.10-alpha] - 2026-09-29

### 变更

- **现场值收敛到一处 `values/value.yml`（入库）**：域名、宿主端口等改这里，跑**一条命令 `gops sys localize`**
  即生效 —— 不再需要 `gops sys update`，也不必动 `sys/merged_vars.yml`；覆盖值会在同一次 localize 内
  一致地进入 `.env`、渲染出的配置（nginx / 网关 toml）与证书 SAN。`sys/setting/vars.yml` 退回**产品默认值**
  （域名默认换成占位），只有碰它才需要 `update` 并把 `sys/merged_vars.yml` 一起提交。
- 文档：`README.md`「变量与本地化」改成这条规则，并写清「改了 `vars.yml` 却没生效」的原因
  （`localize` 不重解析变量，`sys/merged_vars.yml` 在即视为已解析）。

### 修复

- `.gitignore`：同类运行目录的副本（`configs_x/` 等）一并忽略 —— 它们同样含 CA 私钥与 store，别误提交。

## [0.1.9-alpha] - 2026-09-29

### 变更

- 镜像顶版：网关 `v0.1.8-alpha`、前端 `v0.1.7-alpha`。两版带来的变化：
  - 网关：新装 Agent 的**上送目标由部署配置派生**（与网关对外地址同域 + 数据面端口），
    待命期就会把进程列表等事实摘要推上去，派活即开始上送 —— **不必再人工录地址**（录过的仍优先）。
  - 前端：「Gateway 初始化」页改名「Gateway 信息」（`/gateway-info`）并改为只读；去掉控制中心页。
- 安装包改为**只在管理面录入**（`scripts/import-package.sh --set` 或界面「安装包」页）：
  `agent.package_file` 已从配置里删除，不再有「配置里的内置包」这条退路。

### 升级注意

- 新渲染出来的配置（不再含 `agent.package_file`）**不能配 0.1.7 及更早的网关镜像**：
  旧版认这个键为必填，会以 `missing field` 拒绝启动。顺序是**先顶镜像 tag、再 `gops sys localize`**
  —— 本次 tag 已顶好，本地跑过 `gops sys update && gops sys localize` 后即一致。
- 开发态不再自动把本仓 agentd 二进制写进网关配置：要发安装命令时，在「安装包」页录一次它的宿主路径即可（录入会落库，不必每次重启再录）。

## [0.1.8-alpha] - 2026-09-29

### 变更

- 网关镜像顶到 `v0.1.7-alpha`——该版起「内置 agent 安装包」缺失或为空**不再阻断网关启动**，只让安装包分发不可用（需要它的端点被调用时才明确报错）。
- 文档：纠正「`agent.package_file` 指向的文件必须存在」的旧说法。

## [0.1.7-alpha] - 2026-09-29

### 新增

- **一步接管开发态网关**：`scripts/promote-dev-identity.sh` —— 把开发态的**身份 + 管理面状态（SQLite 库）**
  搬成发布态的（只搬文件、**不碰容器**）。库里存着 agent 的凭据，只搬身份不搬库，老 agent 会 401。

### 变更

- `scripts/restore-gateway.sh` 增加恢复范围：`--pem-only`（只身份 PEM）/ `--no-config`（身份 PEM + 库，配置保留目标自己的）。
- 网关 CA 文件统一为 `state/gateway-ca.*`（开发态与发布态**同名**，便于直接对拷）；旧的 `dev-ca.*` 首次运行自动改名迁移（内容/锚不变）。
- 镜像 tag 刷新：VictoriaMetrics → `v1.153.0`、warp-parse → `0.27.1-alpha`（两者均与 `data-plane/`、上游镜像对齐）。

## [0.1.6-alpha] - 2026-09-29

### 新增

- **网关身份备份 / 恢复**：新增 `scripts/backup-gateway.sh`（分 `rebuild` 可重建级 / `restore` 可还原级）与
  `scripts/restore-gateway.sh`。在新机器上用备份即可把网关重建起来，持有效证书的 agent 会自动回连，无需逐台重装。
- **一键切域名**：新增 `dev/setup-domain.sh` —— 换域名只重签叶证书、不动信任锚，agent 无感。

### 变更

- 系统定义收敛到 `sys/`（由 `gops sys` 统一管理）：`docker-compose.yml`、变量（`sys/setting/vars.yml`）、
  配置模板（`sys/configs/`）；部署时经 `gops sys localize` 渲染出运行配置，`configs/` 只放现场生成物。
- 开发态起停收敛为单一入口 `dev/svc.sh`（`start|stop|status`，组件 `vm|wparse|web|gateway`）。
- wparse 运行态拆为两个挂载（输出 `/data/data`、状态 `/data/.run`），不再在宿主运行目录里留下空白挂载点。
- 数据面内置「agent 日志上送网关」的 sink，采集面 OML/WPL 随之入库。
- 网关 / 前端镜像顶到 `v0.1.6-alpha`。
