# wist-gateway-stack

`wist-gateway`（控制面）+ `wist-gateway-web`（前端）+ `WarpParse`（数据平台）+ 观测的一站式编排。

本仓**只做编排**：网关的镜像/二进制制品来自 [`wist-gateway`](https://github.com/dayu-sec/wist-gateway) 仓的 release 流水线，这里引用它们并负责把它们连起来跑。

## 两种运行方式

- **发布态**：Docker 编排（gops 系统，`kind: docker-compose`），`gops run start` 拉起整个栈 —— 变量定义与本地化见「发布态」。
- **开发态**：不依赖 Docker，用本地编译的二进制直接跑（`dev/`）。

两者共享**同一份 wparse 业务配置**（`data-plane/{conf,connectors,models,topology}`，在栈根；发布态只读挂载），环境差异（VictoriaMetrics 地址）通过 `WPARSE_VM_ENDPOINT` 注入，不产生两份配置漂移。
**运行态各自独立**：发布态落 `data-plane-run/data`（`WPARSE_RUN_DATA`）与 `data-plane-run/.run`（`WPARSE_RUN_STATE`），开发态落 `data-plane/{data,.run}` —— 两个引擎可以同时跑，不会互踩。

### 配置与运行态：谁分、谁不分

一条判据：**这份东西「每个环境是否不同」**。

- **`configs/` —— 必须分开**：分开发态 `dev/configs/*` 与发布态 `configs/*`。里面是**每环境不同**的量
  （`admin_api_token`、`public_base_url`、TLS/CA、`victoria_metrics_url`、`[content]` …）且含**密钥**，
  两套无法共用，也**绝不入库**。两份同名 `wist-gateway.toml` 因此长得一模一样 —— 别照着翻错，
  开发态用哪个认准 `./dev/svc.sh token`。
- **`data-plane/` —— 不用分开**：`data-plane/{conf,connectors,models,topology}` 是 warp-parse 的
  **业务配置**，开发态与发布态**共用同一份**（发布态只读挂载）；环境差异靠
  `WPARSE_VM_ENDPOINT` / `WPARSE_GATEWAY_ENDPOINT` 注入，不复制配置、也就不产生漂移。

其中**运行态一律各自独立**（运行态不是配置）：网关 `dev/configs/gateway/state` ↔ `configs/gateway/state`；
wparse `data-plane/{data,.run}` ↔ `data-plane-run/{data,.run}` —— 两侧可同时跑、不互踩。

## 组件

| 服务 | 作用 | 端口（宿主:容器） | 镜像来源 |
|---|---|---|---|
| `gateway` | 控制面后端（HTTPS API，rustls） | `${GATEWAY_PORT}:3000` | `dy-sec.tencentcloudcr.com/cloud/wist-gateway` |
| `web` | 前端入口（nginx：TLS + 静态 + `/api` 反代） | `${WEB_PORT}:443`（HTTPS） | `dy-sec.tencentcloudcr.com/cloud/wist-gateway-web` |
| `wparse` | 数据平台 ELT 引擎 | `${WPARSE_PORT}:9000`（agent 数据入口） | 上游 `ghcr.io/wp-labs/warp-parse`（变量 `WPARSE_IMAGE`） |
| `victoria-metrics` | 指标存储 | `${VM_PORT}:8428` | `victoriametrics/victoria-metrics` |

> **镜像两处源**：两个发布流水线都双推 —— `ghcr.io/dayu-sec/*`（境外）与 `dy-sec.tencentcloudcr.com/cloud/*`（腾讯云 TCR，国内快）。compose 里的镜像源与 tag 都是变量：改**产品默认**改 `sys/setting/vars.yml`（默认 TCR），改**本环境用什么**改 `values/value.yml`（推荐，一条命令生效，见「变量与本地化」）。
>
> **wparse 不同**：它是**上游镜像**（默认 `ghcr.io/wp-labs/warp-parse`，**没有 TCR 镜像**）—— 拉不到 ghcr.io 的环境把 `WPARSE_IMAGE` 指到内网镜像仓库（先把同版本镜像同步过去）即可，`WPARSE_TAG` 不变。它还与 `data-plane/` **强耦合**：引擎版本一变，`conf/connectors/models/topology` 的 schema 可能跟着变，所以 `WPARSE_TAG` 必须钉版本（当前 `0.26.0-beta`，与开发态 `dev/bin/wparse` 同 commit），升级时**连同 `data-plane/` 一起升**。
>
> **挂载约定**（镜像里 `/data` 属非 root 用户 `wparse`(uid 999)）：配置从 `data-plane/` 按目录**只读**挂到 `/data/<name>`（`WPARSE_WORK_DIR`）；运行态**直接挂到 `/data` 的两个子路径**——`${WPARSE_RUN_DATA} → /data/data`、`${WPARSE_RUN_STATE} → /data/.run`。**不挂 `/data` 这一整根**：把运行目录挂成 `/data`、再把配置嵌进去，会让 Docker 在宿主运行目录里建出一堆空白挂载点目录；直接挂两个子路径后，挂载点都建在容器层，宿主目录保持干净。**Linux 部署要保证这两个目录对 uid 999 可写**（`chown -R 999:999 data-plane-run`；OrbStack 会自动放行，Linux 不会）。
>
> **单实例保障**（同一 work root 只能一个引擎；引擎自身没有这层保护）：容器 entrypoint 先用
> `flock --verbose -n -E 75 -F /data/.run/.wparse.lock` 持锁，再把引擎交给 PID 1（`-F` 不 fork，所以
> `docker stop` 的 SIGTERM 直达引擎、能优雅退出；拿不到锁时日志 `flock: failed to get lock`、容器 `Exited (75)`）。
> 开发态 `dev/svc.sh` 的 wparse 启动用**同一位置**的锁（`<work-root>/.run/.wparse.lock`）并额外用
> `docker ps --filter volume=<work-root>` 探测容器。已知边界：macOS 上容器与宿主**不共享** flock
> （work root 是 virtiofs），因此只做到“宿主能发现容器”；反方向靠**运行态目录隔离**（两者默认就不在同一处），
> Linux 上同一内核同一 inode，flock 天然共享。
>
> 这层包装是**绕上游**：引擎本该自己持锁。已提 [wp-labs/warp-parse#365](https://github.com/wp-labs/warp-parse/issues/365)——
> 上游实现单实例保护后，container entrypoint 与 dev 脚本里的锁都可以去掉。
>
> **改了 `sys/setting/vars.yml` 却没生效？** 先看有没有跑 `gops sys update`（`localize` 不重解析它，见「变量与本地化」）。
> 另：`gops 1.3.0` 起 `values/sys_value.yml` 的语义是「覆盖层（注释模板）」，基线是 `sys/merged_vars.yml`；**旧版 gops 留下的全量快照会把所有默认值钉死**。遇到就重生一份：
>
> ```bash
> rm values/sys_value.yml && gops sys update && gops sys localize   # 重生为注释模板；需要覆盖再取消注释
> ```

只接 `victoria-metrics`，不接 `victoria-logs`、`wp-monitor`。

> **端口口径**：网关那侧 **HTTPS**（宿主 `443` → 容器 `3000`，**agentd 直连**，不经代理）；前端那侧 `8443:443`，nginx **自己终止 TLS**（证书是**页面自己的**，`scripts/init-web-tls.sh` 生成），入口 `https://<host>:8443`。两个入口各自独立：页面 nginx 只把浏览器的 `/api` 反代回网关，agentd 直接走网关端口。
>
> **数据面入口**：agent 上送日志/遥测是打到 **wparse 的 `9000`**（`${WPARSE_PORT}:9000`，明文 TCP，需对 agent 网络可达）——和控制面 `443` 是两条独立的通道；agent 用的上送地址由网关管理面下发（`/api/v1/admin/agent/uplink`），要与这个对外端口一致。

## 目录

```
wist-gateway-stack/
  sys-prj.yml               # gops 项目描述
  sys/                      # gops 系统定义（声明文件；随库入库/交付）
    docker-compose.yml      # 发布态：Docker 编排（易变量用 ${VAR} 占位；gops 1.3.3+ 默认在 sys/ 查找）
    sys_model.yml           # kind: docker-compose（gops run 据此分发到 docker compose）
    setting/vars.yml        # 系统变量定义（改默认值改这里）
    resolved_vars.yml       # 生成：gops sys update
    workflows/operators.gxl # 系统运维流程（**本地定义**，不引外部 ops-gxl；含 localize 阶段扩展点）
    configs/
      web/nginx.conf.tpl    # 前端站点配置模板（localize 渲染出 configs/web/nginx.conf，注入 WEB_DOMAIN）
      gateway/wist-gateway.toml.tpl   # 网关配置模板（gx.tpl 渲染出 configs/gateway/wist-gateway.toml）
  data-plane/               # wparse 工程：配置的唯一源（conf/connectors/models/topology；开发态与发布态共用）
    conf/ connectors/ topology/ models/
  data-plane-run/           # 发布态 wparse 运行态根（data/ + .run/ 分别挂到容器 /data/data、/data/.run；不入 git）
  dev/                      # 开发态：单一入口 + 本地二进制
    svc.sh                  # 起/停/看 全栈（vm | wparse | web | gateway）
    setup-domain.sh         # 按需：切域名（建/复用 dev CA + 签叶证书 + 改配置）
    bin/                    # wparse 本地二进制
    configs/                # 开发态：网关运行期配置/密钥（同 configs/ 的形状，但**开发态专用**；不入 git）
      gateway/              # 开发态 wist-gateway.toml + state/（含 admin token，`./dev/svc.sh token` 可取）
  configs/                  # 运行期配置/密钥（现场生成，不入 git / 不入包）
    gateway/                # 发布态：wist-gateway.toml（由模板渲染）+ state/（证书/密钥/store/包缓存）
    web/                    # 发布态：nginx.conf（由模板渲染）+ nginx.value.json + tls/（证书）
  packages/                 # 安装包投放目录（宿主；只读挂到网关 /packages；不入 git）
  scripts/                  # 发布态初始化脚本
    init-gateway.sh         # 网关 CA/叶证书/签名密钥/渲染值（幂等；由 localize 阶段流程调用）
    init-web-tls.sh         # 前端站点 TLS 证书（幂等）
    init-web-conf.sh        # 前端站点配置的渲染值 configs/web/nginx.value.json（幂等；域名取 WEB_DOMAIN）
    align-host-perms.sh     # 宿主属主/权限对齐（属主=部署账号、属组=容器 gid 999、目录 2770、私钥 640；幂等）
    import-package.sh       # 导入 agent 安装包到 packages/（--set 可顺手设为分发来源）
    import-knowledge.sh     # 导入知识库内容包到 packages/（--set 录入、--activate 当场生效；不录就是**空载**）
    init-knowledge-signing.sh # （可选）放置知识库验签公钥；给了就**强制验签**内容包
    backup-gateway.sh       # 备份网关**身份与配置**（两级 --level）；数据库与历史不用备（见「备份与恢复」）
    restore-gateway.sh      # 从备份恢复（新机器重建）；库/历史不需要恢复
    promote-dev-identity.sh # 一步：把开发态身份 + 库搬成发布态的（只搬文件，不碰容器；--dry-run 预演）
  .github/workflows/release.yml     # 打包发布（见「制品包」）
  README.md
```

> **数据目录**：**开发态与发布态分开两个目录** —— 开发态（`./dev/svc.sh start`）落 `dev/configs/gateway/`，发布态挂 `configs/gateway/`（两边需要的值不同：`victoria_metrics_url`、`public_base_url`、是否装 `[content]` 等）。两者都是 `wist-gateway.toml` + `state/`（SQLite 库 / TLS / 签名密钥），与运行期临时目分离，清 `.run` 不会丢 agents 注册表。发布态通过 `sys/docker-compose.yml` 把它挂进容器。

> **持久化**：网关把 Agent 注册表与注册 Token 存在内嵌 SQLite 库里（默认 `configs/gateway/state/wist-gateway.db`，即已挂载的卷内），**不需要额外容器或端口**，compose 无需改动；schema 在启动时自动迁移。**这个库不用备份**：库丢了，持有效客户端证书的 agent 会在重连时自动重新登记（mTLS 自愈）——真正不可再生的只有 PEM（见「备份与恢复」）。若将来要多副本负载均衡，需换成共享数据库（网关支持用 `WIST_GATEWAY_DATABASE_URL` 指定 DSN，当前实现只支持 `sqlite:`）。

## 发布态（经 gops 管理）

本栈是一个 gops 系统（`sys/sys_model.yml` 里 `kind: docker-compose`），起停走 `gops run`，它分发到对应的 `docker compose` 子命令：

### 前置：主机要求

| 项 | 要求 | 怎么验 |
|---|---|---|
| Docker + Compose V2 | `docker compose` 是 **CLI 插件**；只有老的 `docker-compose` v1 不够 | `docker compose version` 能打印 `v2.x` |
| 执行账号 | 普通账号 + **已加入 `docker` 组**（等价于本机高权限，按安全要求评估）；部署目录由它拥有 | `id -nG`（输出里应含 `docker`） |
| 端口 | 宿主 `443`（网关，agentd 直连）、`8443`（页面）、`9000`（数据面）、`18429`（指标） | 见 `sys/setting/vars.yml` |

> 为什么必须 Compose V2：`gops run` 固定发 `docker compose …`，**没有 v1 回退**。缺插件时报的是
> `unknown shorthand flag: 'f' in -f`（docker 认不出 `compose`，就继续把后面的 `-f` 当自己的全局选项），
> 很误导。Ubuntu 上装 `docker-compose-v2`（或 Docker 官方源的 `docker-compose-plugin`）即可。

| 命令 | 实际执行 |
|---|---|
| `gops run download` | `docker compose pull` |
| `gops run install` | `docker compose create` |
| `gops run start` | `docker compose up -d` |
| `gops run stop` | `docker compose stop` |
| `gops run uninstall` | `docker compose down` |
| `gops run status` | `docker compose ps` |
| `gops run diagnose` | `docker compose config` |

### 变量与本地化

**一条规则：现场值只写 `values/value.yml`（入库），改完跑 `gops sys localize` 即生效** ——
不需要 `update`，也不用动 `sys/merged_vars.yml`。覆盖值会在同一次 localize 内一致地进入
`.env`、渲染出的配置（nginx / 网关 toml）与证书 SAN。

```bash
vim values/value.yml      # 改域名 / 宿主端口等现场值（已跟踪，不忽略）
gops sys localize         # 一条命令：渲染配置 + 导出 .env（compose 读它）
```

`sys/setting/vars.yml` 是**产品默认值**（随仓走的基线），现场一般**不用碰**。确实要改产品默认时：

```bash
gops sys update           # 解析 vars.yml → sys/merged_vars.yml（入库，要一起提交）
gops sys localize
```

> 为什么区分：`localize` **不会**重新解析 `vars.yml`（`sys/merged_vars.yml` 在就等于「已解析」，
> 只在它缺失时才自动补跑 update）。所以改了 `vars.yml` 不跑 `update` 不生效 —— 而覆盖值是在
> localize 的合并阶段生效的，一条命令就够。

**`localize` 还会跑项目自己的阶段流程**：写完 `.env` 后，若系统定义了 `localize` 流程，`gops sys localize` 就执行 `gx run localize`（galaxy-ops ≥ 1.3.4 / galaxy-flow ≥ 0.14）。本栈把它定义在 `sys/workflows/operators.gxl`（**本地定义**，不引外部 ops-gxl），由 `_gal/work.gxl` 的 `mod main : operators` 纳入；合并后的值以**环境变量**注入该流程（用 `$(printenv XXX)` 读）。流程里做六件**幂等**的事：

1. 备料 `configs/gateway/`：Ed25519 签名密钥、网关 TLS 证书、渲染值 `wist-gateway.value.json`（`scripts/init-gateway.sh`，缺什么补什么）；
2. 渲染 `configs/gateway/wist-gateway.toml`（模板在 `sys/configs/gateway/wist-gateway.toml.tpl`）；
3. 生成前端站点 TLS 证书（`scripts/init-web-tls.sh`，存在即跳过；域名取 `WEB_DOMAIN`）；
4. 写前端站点配置的**渲染值** `configs/web/nginx.value.json`（`scripts/init-web-conf.sh`；域名取 `WEB_DOMAIN`）；
5. 渲染前端站点配置 `configs/web/nginx.conf`（模板 `sys/configs/web/nginx.conf.tpl`，注入 `WEB_DOMAIN`）；
6. **宿主属主/权限对齐**（`scripts/align-host-perms.sh`，见下「权限与运行身份」；非 Linux 自动跳过）。

> 第 6 步必须在 `docker compose up` **之前**：Docker 会把缺失的挂载源目录自行建成 `root:root`，
> 属主一旦是 root，之后的部署账号就写不动了（见「权限与运行身份」）。

`gops sys localize --no-flow` 可跳过该流程；未装 gx 或无该流程时静默跳过。

> 本栈当前无密钥；将来若需要，compose 里用 `${SEC_xxx}` 占位，由 `gops run start` 从 `~/.galaxy/sec_value.yml` 注入，不落盘。

### 前置：挂载文件

compose 还挂这些路径：

1. `configs/gateway/` —— 网关配置与密钥。**仓库不含**，由 `scripts/init-gateway.sh` 现场备料 + 模板渲染（见下 A）。
2. `sys/configs/web/nginx.conf.tpl` —— 前端站点配置**模板**。**仓库自带**，由 `gops sys localize` 渲染到 `configs/web/nginx.conf`（注入 `WEB_DOMAIN` → `server_name`）：443 上终止 TLS、托管前端静态产物、SPA 深链回退到 `index.html`、把 `/api` 反代到 `gateway:3000`（网关那侧是**自签 HTTPS**，已关掉证书校验）。
3. `configs/web/tls/` —— 前端站点 TLS 证书/私钥（**页面自己的**，与网关分开）。用 `scripts/init-web-tls.sh <域名>` 在目标机现场生成。
4. `packages/`（`${PACKAGE_DIR}`）—— 安装包**投放目录**，只读挂到网关容器 `/packages`。用 `scripts/import-package.sh` 导入（见下 A）；界面「本地来源」填 **`/packages/<文件名>`**（容器读不到宿主任意路径；或改用 `https://...` URL）。

### 权限与运行身份（Linux 必读）

两个业务镜像**固定以 `999:999` 运行**（`gateway` 镜像里的 `wist`、`wparse` 镜像里的 `wparse`；compose 里 `user:` 已显式钉死）。bind 挂载在 Linux 上**不改变属主**，所以宿主侧必须显式对齐，否则必然出现两个稳定故障：

| 症状 | 现场表现 | 根因 |
|---|---|---|
| wparse 无限重启 | `flock: cannot open lock file /data/.run/.wparse.lock: Permission denied`，容器 `Exited (75)` | `data-plane-run/{data,.run}` 对 uid 999 不可写 |
| gateway 无限重启 | `failed to read install script signing key …: Permission denied (os error 13)` | `configs/gateway/state/*.pem`（600 且属主不是 999）容器读不到 |

（web 跟着起不来、报 `host not found in upstream "gateway"` 只是被网关拖累，网关一好它自愈。）

**唯一入口是 `scripts/align-host-perms.sh`**（`gops sys localize` 会自动跑，也可单独跑）：

- **属主 = 部署账号**（取 `SUDO_UID`/`SUDO_GID`）：它要改配置、跑备份/恢复 —— 所以 `backup-gateway.sh` / `restore-gateway.sh` **不需要提权**；
- **属组 = 容器 gid `999`**：容器进程天然在这个组里；
- 挂载目录分两档：**需要容器写**的 `2770`（组可写 + **setgid**，目录里新建的文件/目录自动继承该组）、**容器只读**的 `2755`；私钥与含密钥的 `wist-gateway.toml` 为 `640`（不放宽到全局：其它宿主账号连 `2770` 目录都进不去）；
- **SQLite 库**（`state/*.db*`）：容器自建的（`999:999`）**不碰** —— 否则每次 `localize` 都要提权；但**恢复搬过来的库**属主是部署账号，会放开到属组可写（`660`）—— 不然网关只能读不能写，报 `unable to open database file` / `readonly database`；
- `state/*.srl`（CA 序列号）归部署账号：宿主 `openssl` 重新签叶时要写它，曾被 root 跑过就会卡住后续非 root 的签叶；
- **不依赖「目录是谁创建的」**：`docker compose up` 会把缺失的挂载源目录建成 `root:root`，本脚本把属主/属组一并纠回来；
- **幂等**：已对齐时不写盘、也不要任何权限（所以日常 `localize` 不会再要 sudo）；确需修正而当前没权限时会失败，并打印那一行 `sudo` 命令 —— **全新主机第一次 `localize` 通常就属这种情况**（要把属组改成 999），免密 sudo 时脚本会自己重跑；
- **边界**：只对齐**挂载根与私钥**，不递归内容树（`configs/gateway/knowledge/`、`packages/` 里的文件由打包/投放侧保证 644/755 可读）；
- **非 Linux 自动跳过**（macOS / OrbStack 的 bind 挂载不校验属主）—— 这也是「macOS 上一直好好的、上 Linux 才炸」的原因。

> 新机器用备份重建：`restore-gateway.sh` 解包出的文件属组是「解包账号」的（tar 以非 root 解包保不住属主），
> 所以它在目标为 `configs/gateway` 时会**自动**再跑一次对齐。

### A. 宿主机显式初始化（推荐生产）

```bash
# 备料 + 渲染 + 生成页面证书，一步到位（就是 localize 的阶段流程）
gops sys update && gops sys localize

# 它做六件事（都幂等）：
#   scripts/init-gateway.sh configs/gateway   # 网关 CA + 叶证书(CA签) + Ed25519 签名密钥 + value.json
#   gx.tpl 渲染 sys/configs/gateway/wist-gateway.toml.tpl → configs/gateway/wist-gateway.toml
#   scripts/init-web-tls.sh $WEB_DOMAIN       # 前端站点证书
#   scripts/init-web-conf.sh $WEB_DOMAIN      # 前端站点配置的渲染值 nginx.value.json
#   渲染 configs/web/nginx.conf               # 前端站点配置（注入域名）
#   scripts/align-host-perms.sh               # 宿主属主/权限对齐（容器 999:999；须在 start 之前）

# 起服务（安装包不是配置项：要发安装命令就先录入来源，见下一条；没录也不阻断启动）
gops run start

# 投放 agent 安装包并设为分发来源（容器读**不到**宿主机路径 → 统一走 /packages）：
#   --latest 取 ../wist-agentd/target/package 最新；也可传具体文件/目录
./scripts/import-package.sh --latest --set
#   等价于：cp 到 packages/ + 调管理 API 把来源设为 /packages/<文件名>

# 投放**知识库内容包**（采集目录/包/模板 + 用途规则 + 发现策略）。
# 不录就是空载：不产「系统类型」建议、不产用途建议（发现策略走 agentd 内建默认值）。
#   知识库是**录入 ≠ 生效**：--set 只录入，--activate 才当场切（旧版工作不被追改，见网关设计稿 §8）。
#   包从 wist-knowledge 的 Release 下载（wist-knowledge-<版本>.tar.gz），或本地 `scripts/package.sh` 打一个。
./scripts/import-knowledge.sh --latest --set --activate

# （可选）让网关**强制验签**内容包：给公钥，localize 会渲染出 `[knowledge]` 段
#   公钥在 wist-knowledge 仓的 keys/knowledge-signing.pub.pem（同级仓时自动取，不用给路径）。
#   启用后**只收**发布侧签过的包（未签名的会被拒：package_signature_invalid）。
KNOWLEDGE_SIGNING_PUBKEY=/path/to/knowledge-signing.pub.pem gops sys localize
#   关掉：rm configs/gateway/state/knowledge-signing.pub.pem && gops sys localize

# 改了证书/配置后，必须**重启网关容器**才生效（`up -d` 不会因挂载文件变化而重建）：
docker compose --project-directory . -f sys/docker-compose.yml restart gateway
```

> 域名 / 端口改 **`values/value.yml`**（现场值的唯一入口），跑 `gops sys localize` 后重启网关容器即生效；只有改产品默认 `sys/setting/vars.yml` 才需要先 `gops sys update`。若换了域名，前端站点证书要 `rm -rf configs/web/tls` 让它按新域名重签（网关叶证书会自动重签）。
>
> **身份模型（CA 签叶）**：`scripts/init-gateway.sh` 建一张**网关 CA**（`state/gateway-ca.{crt,key}.pem`），网关**叶证书由它签发**，agent 的信任锚 = **CA 根**（配置 `agent.trust_bundle_file = state/gateway-ca.crt.pem`）。于是**换域名 / 续期 / 换 SAN 只重签叶证书，锚不变、agent 无感**。
> **CA 私钥不可再生**：`state/gateway-ca.key.pem` 丢了 = 换锚 = **全队 agent 重装**，务必备份（见「备份与恢复」）。

### B. 容器自动初始化（零配置）

bootstrap 镜像首次启动会自己生成 config + 自签证书 + 签名密钥，并把 `listen_addr` 改成 `0.0.0.0:3000`：

```bash
cd ../wist-gateway/docker
docker build -t wist-gateway:latest -f Dockerfile .
docker build -t wist-gateway:bootstrap -f Dockerfile.bootstrap .

# 把 compose 里 gateway 的 image 改成 wist-gateway:bootstrap（本地联调用），然后
cd ../../wist-gateway-stack
gops sys update && gops sys localize
gops run start
```

生成物落在挂载卷 `configs/gateway/` 里，所以能复用；**不挂卷就会每次重启换一套**（新证书 + 新 admin token + 新签名密钥，已发出的安装命令和 agent 凭据全部失效）。

### 起停与排查

```bash
gops run status       # 容器状态
gops run stop         # 停
gops run uninstall    # 停并删容器（不删卷）
gops run diagnose     # 渲染后的 compose 配置：排查变量/端口/挂载
```

### 起来之后

- 前端入口：`https://<host>:8443`（nginx 终止 TLS，证书是页面自己的；首访浏览器会提示自签不受信）
- 网关 API：`https://<host>:3000`

## 开发态（本地二进制）

```bash
# 唯一入口：构建一次 → 五个组件（VM/wparse/web/forward/gateway）全部后台常驻
./dev/svc.sh start
./dev/svc.sh start --dry-run     # 先看会起哪些/跳过哪些（不启动）
./dev/svc.sh status              # 看各组件当前状态
./dev/svc.sh stop                # 逆序停全栈

# 只操作某个组件（组件：vm | wparse | web | forward | gateway）
./dev/svc.sh start web           # 只重启前端（gateway 已在跑时）
./dev/svc.sh stop gateway

# 按需一次性工具（不属于 start 流程）
./dev/setup-domain.sh <域名>     # 换域名（改配置 + 重签证书；改完需重启 gateway）
./dev/link_local_center.sh       # 快速路：把本机网关接入本机中心（免页面、免手写 gwlinkd.toml）
```

> `svc.sh` 与发布态的 `gops run start|stop|status` 对应：`start` 把五个组件（vm/wparse/web/forward/gateway）
> 全部**后台常驻**拉起、已在跑则跳过，**起完即返回**（不占终端）；整栈停止用 `./dev/svc.sh stop`。

`./dev/link_local_center.sh` 是**接入上级（控制中心）的快速路**：gwlinkd 是网关**宿主侧**的容器外常驻
（随网关走，所以脚本在本仓 `dev/` 而非 center-stack），除了页面「链接上级」，dev 还多这条命令行捷径 ——
自动建/复用中心实例、取一次性接入券、写 `gwlinkd.toml`、后台跑 gwlinkd（link-upstream → register
→ 周期 status，此后走 mTLS）。前提是本机中心已在跑（`wist-center-stack` 的 `./dev/svc.sh start`）；
停用 `./dev/link_local_center.sh --stop`。

`svc.sh start gateway` 会自动做这几件事：**启动时 `cargo build` 一次 `wist-gateway` 与 `wist-agentd`**（保证跑的是当前源码，`--no-build` / `SKIP_BUILD=1` 可跳过）；缺配置就调 `wist-gateway init-config` 生成到 `dev/configs/gateway/`；缺 TLS 证书就 `openssl` 签一张叶证书；**并把信任锚写进 `[agent] trust_bundle_file`**（跑过 `dev/setup-domain.sh` 就有 `gateway-ca.crt.pem`，锚 = CA 根；没有就退回叶证书自身；供 install.sh 内嵌 `--cacert` 用）。

前置：本地有 Rust 工具链（脚本会 `cargo build` `wist-gateway` / `wist-agentd`）、`wist-gateway-web/node_modules`（先 `npm install`）、`dev/bin/` 里有 wparse 二进制。日志：`/tmp/wist-gateway-server.log`、`/tmp/wist-gateway-web.log`。

## 制品包（发布）

`.github/workflows/release.yml` 在 `v*.*.*` 标签上打包并发布：**整仓内容（除 CI 自身的 `.github/`）**。

```bash
wist-gateway-stack-<tag>.tar.gz
  sys/ + sys-prj.yml          # gops 系统定义 + 声明文件（docker-compose.yml、sys_model、setting/vars.yml、resolved_vars.yml、configs/{web/nginx.conf.tpl,gateway/*.tpl}）
  data-plane/                 # wparse 工程（conf/connectors/models/topology）
  dev/                        # 开发态启停脚本（bin/ 不入 git）
  _gal/                       # gx 工作流
  version.txt
  README.md / .gitignore
```

> 包内**不要加顶层目录前缀**：`gops` 解包时会自建同名目录（`~/ds-package/<包名>/`），包内再套一层会导致 `prj import` 找不到 `sys/sys_model.yml`。
>
> 包里的变量解析产物 `sys/merged_vars.yml`（`prj import` 缺了会报“系统变量未解析”）：gops 文档标注它**需入库**，所以它随仓库一起进包 —— **改了 `sys/setting/vars.yml` 后要本地跑一次 `gops sys update` 并提交它**，否则包里带的是旧值。CI 里不跑 gops，包内容完全由 `git archive` 决定。

用 `git archive` 出包，只收 git 跟踪的内容 —— `dev/bin/`（约 92M 二进制）、`data-plane/{data,.run}/`、`_gal/.report`、以及 gops 生成物（`.env`、`values/`）都没入 git，天然不入包。

包里**含 `sys/configs/web/nginx.conf.tpl`**（前端站点配置随仓走）**但不含任何私钥/证书**：`configs/gateway/`（网关配置 + 密钥）与 `configs/web/`（页面配置 + 证书）都在目标机现场生成。下载解压后跑一次 `gops sys update && gops sys localize` 即可（备料 + 渲染 + 页面证书一步到位，见「发布态 A」）。

## 环境接线

wparse 里指向 VictoriaMetrics 的端点用 `${WPARSE_VM_ENDPOINT}` 占位，由运行环境注入：

- 开发态：`svc.sh` 起 wparse 时默认 `http://127.0.0.1:18429`。
- 发布态：compose 注入 `http://victoria-metrics:8428`。

## 已知坑

1. **网关启动的硬要求**（缺失即拒绝启动，`wist-gateway` 的 `AdminConfig::validate`）：`wist-gateway.toml` 本身、TLS 证书与私钥、Ed25519 签名私钥；`public_base_url` 必须是 `https://`；`admin_api_token` 要满足长度与熵要求。这就是"为什么必须先初始化"。**安装包不是配置项**：`agent.package_file` 已删（gateway 0.1.8 起），安装包只有「管理面录入」一个来源（用 `scripts/import-package.sh --set` 或界面「安装包」页）；**没录入也不阻断启动**，只让安装包分发不可用（相关端点被调用时才明确报错）。
2. **信任锚走文件，且是 CA 根**。配置用 `agent.trust_bundle_file = state/gateway-ca.crt.pem`（相对配置目录），由 `scripts/init-gateway.sh` 生成；网关启动时读该文件，并把它下发给 agent（写进 `install.sh` / `agentd.toml`）。旧的 `agent.trust_bundle = """..."""` 内联写法已移除。
3. **叶证书必须带 `basicConstraints=CA:FALSE`（叶形态）、且由网关 CA 签**。`openssl req -x509` 的旧默认会打 `CA:TRUE`，rustls/webpki 会以 `CaUsedAsEndEntity` 拒收；`scripts/init-gateway.sh` 生成的叶证书是 `CA:FALSE` + `serverAuth`，并由网关 CA 签发。**轮换叶证书（换域名 / 续期）是安全的**——锚 = CA 根不变，agent 无感；只有当**锚本身**变了（换 CA / 删掉 `gateway-ca.*` 重生成）才需要**重跑安装**（仅重新注册不刷新锚）。
4. **改证书/配置后要重启网关容器**：`gops run start`（`up -d`）**不会**因挂载文件变化而重建容器，网关只在**启动时**读 `wist-gateway.toml` 与证书。用：`docker compose --project-directory . -f sys/docker-compose.yml restart gateway`。
5. **镜像 tag 是浮动 `:latest`**。同一份 compose 在不同时间拉到的镜像可能不同，升级也对不齐；生产建议钉到固定版本（必要时加 `@sha256:` 摘要），做法就是改 `sys/docker-compose.yml` 里 `gateway` / `web` 的 `image`。
6. **容器读不到宿主路径**（设置安装包来源时最常见）。网关对**以 `/` 开头的来源**是在**它自己的**文件系统里 `fs::read`；compose 下只有被挂进来的目录可见。所以「本地来源」只能是**容器内路径**：`/packages/<文件名>`（投放目录，见 `scripts/import-package.sh`）或 `/config/<文件名>`（配置目录），否则报 `failed to read package from <宿主路径>: No such file or directory`（界面表现为 502）。拉取成功后网关会把包缓存到 `configs/gateway/state/install-package/`（在挂载卷里，可备份）。
   > 提醒：**别删 `packages/` 目录本身**（容器正挂载它）——删了会让挂载失效、容器内 `/packages` 直接消失；重建容器才恢复（`docker compose --project-directory . -f sys/docker-compose.yml up -d --force-recreate gateway`）。
7. **宿主属主/权限没对齐 → 容器无限重启**（Linux 上最常见的部署事故）。症状与处置见「权限与运行身份」：跑一次 `scripts/align-host-perms.sh`（需要时加 `sudo`），或在恢复备份后重跑一次（`restore-gateway.sh` 会自动跑）。**别用 `docker compose up` 顺手建目录** —— 它建出来的是 `root:root`。

## 备份与恢复

**要备份的核心是身份 PEM；数据库与历史都不用备**：

```bash
# 备份分两级（--level）：rebuild = 可重建级（默认）；restore = 可还原级
./scripts/backup-gateway.sh --from configs/gateway                    # 可重建级 → ./wist-gateway-backup-<时间戳>.tar.gz
./scripts/backup-gateway.sh --level restore --from configs/gateway    # 可还原级（再加 value.json + SQLite 库）
./scripts/backup-gateway.sh check --from configs/gateway              # 先看会备份哪些件（不写文件）
./scripts/backup-gateway.sh list                                      # 列已备份的归档；list <归档文件> 看它里面有哪些件

# 恢复（独立脚本；默认目标目录 configs/gateway，默认不覆盖已有文件，加 --force 才覆盖）
./scripts/restore-gateway.sh <备份文件> [--to configs/gateway] [--pem-only] [--force] [--restart]
```

- **可重建级**（`--level rebuild`，默认）：把网关**重新立起来**所需的全部 —— 身份 PEM（`state/gateway-ca.key.pem`＝信任锚，丢了 = 全队 agent 用新 CA 重装；`state/agent-ca.key.pem`＝签客户端证书的 CA；叶证书 / 签名密钥，带上省一次重签）＋ 渲染好的 `wist-gateway.toml`。恢复后**直接起网关即可**，无需再跑 `gops sys localize`。
- **可还原级**（`--level restore`）：在可重建级之上，再带 `wist-gateway.value.json`（渲染源；保住原 admin token，便于重渲染）与 **SQLite 库**（派活、安装包录入、用途与上送绑定等**管理面状态**）—— 按原样还原运行状态。
- **只搬身份**：`restore-gateway.sh --pem-only` 只恢复 `.pem`（CA / 叶证书 / 签名私钥），跳过 toml / value.json / 库。**注意**：库里存着 agent 的**凭据**，只搬 PEM 会让老 agent **401**。
- **一步搬身份（+ 库）**：`scripts/promote-dev-identity.sh`（默认 `--from <栈根>/dev/configs/gateway --to <栈根>/configs/gateway`）—— 把开发态的**身份 + 管理面状态（SQLite 库）**搬成发布态的（`--level restore` 出包 + `--no-config` 恢复，**配置不动**）。**只搬文件、不碰容器**；`--dry-run` 可先预演。要让老 agent **无感**回来，用这个（只搬 PEM 不够）。
- 两级都**不含**（都可重生成/重导入）：指标历史（VictoriaMetrics 卷）、安装包缓存、页面证书、`content/`。
- 恢复后重启网关即可，持有效证书的 agent **自动回来，无需逐台重装**。
- 开发态同样可用：`./scripts/backup-gateway.sh --from dev/configs/gateway`。
