# 更新日志

本文件记录 `wist-gateway-stack` 的所有重要变更。格式遵循 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

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
