# 更新日志

本文件记录 `wist-gateway-stack` 的所有重要变更。格式遵循 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

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
