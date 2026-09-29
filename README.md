# wist-gateway-stack

`wist-gateway`（控制面）+ `wist-gateway-web`（前端）+ `WarpParse`（数据平台）+ 观测的一站式编排。

本仓**只做编排**：网关的镜像/二进制制品来自 [`wist-gateway`](https://github.com/dayu-sec/wist-gateway) 仓的 release 流水线，这里引用它们并负责把它们连起来跑。

## 两种运行方式

- **发布态**：Docker 编排（gops 系统，`kind: docker-compose`），`gops sys start` 拉起整个栈 —— 变量定义与本地化见「发布态」。
- **开发态**：不依赖 Docker，用本地编译的二进制直接跑（`dev/`）。

两者共享**同一份 wparse 业务配置**（`data-plane/{conf,connectors,models,topology}`，在栈根；发布态只读挂载），环境差异（VictoriaMetrics 地址）通过 `WPARSE_VM_ENDPOINT` 注入，不产生两份配置漂移。
**运行态各自独立**：发布态落 `data-plane-run/data`（`WPARSE_RUN_DATA`）与 `data-plane-run/.run`（`WPARSE_RUN_STATE`），开发态落 `data-plane/{data,.run}` —— 两个引擎可以同时跑，不会互踩。

## 组件

| 服务 | 作用 | 端口（宿主:容器） | 镜像来源 |
|---|---|---|---|
| `gateway` | 控制面后端（HTTPS API，rustls） | `${GATEWAY_PORT}:3000` | `dy-sec.tencentcloudcr.com/cloud/wist-gateway` |
| `web` | 前端入口（nginx：TLS + 静态 + `/api` 反代） | `${WEB_PORT}:443`（HTTPS） | `dy-sec.tencentcloudcr.com/cloud/wist-gateway-web` |
| `wparse` | 数据平台 ELT 引擎 | `${WPARSE_PORT}:9000`（agent 数据入口） | 上游 `ghcr.io/wp-labs/warp-parse`（变量 `WPARSE_IMAGE`） |
| `victoria-metrics` | 指标存储 | `${VM_PORT}:8428` | `victoriametrics/victoria-metrics` |

> **镜像两处源**：两个发布流水线都双推 —— `ghcr.io/dayu-sec/*`（境外）与 `dy-sec.tencentcloudcr.com/cloud/*`（腾讯云 TCR，国内快）。compose 里的镜像源与 tag 都是变量，定义在 `sys/setting/vars.yml`（默认 TCR）；改源或钉版本改那里，或在该系统的 `values/value.yml` 做客户覆盖，再 `gops sys update && gops sys localize` 重新生成 `.env`。
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
> **改完 vars.yml 记得确认 `.env` 真的变了**：`gops 1.3.0` 起 `values/sys_value.yml` 的语义是「覆盖层（注释模板）」，基线是 `sys/merged_vars.yml`；而**旧版 gops 留下的全量快照会把所有默认值钉死**（症状：改了 `vars.yml`，`gops sys update && gops sys localize` 后 `.env` 还是旧值）。遇到就这样重生一份：
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
    sys_model.yml           # kind: docker-compose（gops sys 据此分发到 docker compose）
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
    re-enroll.sh            # 按需：重注册本机 wist-agentd
    bin/                    # wparse 本地二进制
  configs/                  # 运行期配置/密钥（现场生成，不入 git / 不入包）
    gateway/                # 发布态：wist-gateway.toml（由模板渲染）+ state/（证书/密钥/store/包缓存）
    web/                    # 发布态：nginx.conf（由模板渲染）+ nginx.value.json + tls/（证书）
  packages/                 # 安装包投放目录（宿主；只读挂到网关 /packages；不入 git）
  scripts/                  # 发布态初始化脚本
    init-gateway.sh         # 网关 CA/叶证书/签名密钥/渲染值（幂等；由 localize 阶段流程调用）
    init-web-tls.sh         # 前端站点 TLS 证书（幂等）
    import-package.sh       # 导入 agent 安装包到 packages/（--set 可顺手设为分发来源）
  .github/workflows/release.yml     # 打包发布（见「制品包」）
  README.md
```

> **数据目录**：**开发态与发布态分开两个目录** —— 开发态（`./dev/svc.sh start`）落 `~/.wist-gateway/`，发布态挂 `configs/gateway/`（两边需要的值不同：`victoria_metrics_url`、`public_base_url`、是否装 `[content]` 等）。两者都是 `wist-gateway.toml` + `state/`（SQLite 库 / TLS / 签名密钥），与运行期临时目分离，清 `.run` 不会丢 agents 注册表。发布态通过 `sys/docker-compose.yml` 把它挂进容器。

> **持久化**：网关把 Agent 注册表与注册 Token 存在内嵌 SQLite 库里（默认 `configs/gateway/state/wist-gateway.db`，即已挂载的卷内），**不需要额外容器或端口**，compose 无需改动。schema 在启动时自动迁移；备份该文件即可备份注册表，删掉它则所有 Agent 需要重新注册。若将来要多副本负载均衡，需换成共享数据库（网关支持用 `WIST_GATEWAY_DATABASE_URL` 指定 DSN，当前实现只支持 `sqlite:`）。

## 发布态（经 gops 管理）

本栈是一个 gops 系统（`sys/sys_model.yml` 里 `kind: docker-compose`），起停都走 `gops sys`，它分发到对应的 `docker compose` 子命令：

| 命令 | 实际执行 |
|---|---|
| `gops sys download` | `docker compose pull` |
| `gops sys install` | `docker compose create` |
| `gops sys start` | `docker compose up -d` |
| `gops sys stop` | `docker compose stop` |
| `gops sys uninstall` | `docker compose down` |
| `gops sys status` | `docker compose ps` |
| `gops sys diagnose` | `docker compose config` |

### 变量与本地化

compose 里随环境/客户变的量（镜像源与 tag、宿主端口、保留期、时区、挂载路径）都是 `${VAR}` 占位，定义在 `sys/setting/vars.yml`。改默认值就改它；**客户/环境覆盖写 `values/value.yml`**，不要改生成物。然后按顺序跑：

```bash
gops sys update      # 解析变量 → sys/resolved_vars.yml（+ values/sys_value.yml）
gops sys localize    # 合并默认值与 values/value.yml → .env（compose 读它）
```

**`localize` 还会跑项目自己的阶段流程**：写完 `.env` 后，若系统定义了 `localize` 流程，`gops sys localize` 就执行 `gx run localize`（galaxy-ops ≥ 1.3.4 / galaxy-flow ≥ 0.14）。本栈把它定义在 `sys/workflows/operators.gxl`（**本地定义**，不引外部 ops-gxl），由 `_gal/work.gxl` 的 `mod main : operators` 纳入；合并后的值以**环境变量**注入该流程（用 `$(printenv XXX)` 读）。流程里做三件**幂等**的事：

1. 备料 `configs/gateway/`：Ed25519 签名密钥、网关 TLS 证书、渲染值 `wist-gateway.value.json`（`scripts/init-gateway.sh`，缺什么补什么）；
2. 渲染 `configs/gateway/wist-gateway.toml`（模板在 `sys/configs/gateway/wist-gateway.toml.tpl`）；
3. 生成前端站点 TLS 证书（`scripts/init-web-tls.sh`，存在即跳过；域名取 `WEB_DOMAIN`）；
4. 渲染前端站点配置 `configs/web/nginx.conf`（模板 `sys/configs/web/nginx.conf.tpl`，注入 `WEB_DOMAIN`）。

`gops sys localize --no-flow` 可跳过该流程；未装 gx 或无该流程时静默跳过。

> 顺序不能反：先 `update` 再 `localize`。
> 本栈当前无密钥；将来若需要，compose 里用 `${SEC_xxx}` 占位，由 `gops sys start` 从 `~/.galaxy/sec_value.yml` 注入，不落盘。

### 前置：挂载文件

compose 还挂这些路径：

1. `configs/gateway/` —— 网关配置与密钥。**仓库不含**，由 `scripts/init-gateway.sh` 现场备料 + 模板渲染（见下 A）。
2. `sys/configs/web/nginx.conf.tpl` —— 前端站点配置**模板**。**仓库自带**，由 `gops sys localize` 渲染到 `configs/web/nginx.conf`（注入 `WEB_DOMAIN` → `server_name`）：443 上终止 TLS、托管前端静态产物、SPA 深链回退到 `index.html`、把 `/api` 反代到 `gateway:3000`（网关那侧是**自签 HTTPS**，已关掉证书校验）。
3. `configs/web/tls/` —— 前端站点 TLS 证书/私钥（**页面自己的**，与网关分开）。用 `scripts/init-web-tls.sh <域名>` 在目标机现场生成。
4. `packages/`（`${PACKAGE_DIR}`）—— 安装包**投放目录**，只读挂到网关容器 `/packages`。用 `scripts/import-package.sh` 导入（见下 A）；界面「本地来源」填 **`/packages/<文件名>`**（容器读不到宿主任意路径；或改用 `https://...` URL）。

### A. 宿主机显式初始化（推荐生产）

```bash
# 备料 + 渲染 + 生成页面证书，一步到位（就是 localize 的阶段流程）
gops sys update && gops sys localize

# 它做四件事（都幂等）：
#   scripts/init-gateway.sh configs/gateway   # 网关 CA + 叶证书(CA签) + Ed25519 签名密钥 + value.json
#   gx.tpl 渲染 sys/configs/gateway/wist-gateway.toml.tpl → configs/gateway/wist-gateway.toml
#   scripts/init-web-tls.sh $WEB_DOMAIN       # 前端站点证书
#   渲染 configs/web/nginx.conf               # 前端站点配置（注入域名）

# 起服务（另：agent.package_file 指向的**内建**包需在 configs/gateway/ 里，启动时校验存在）
gops sys start

# 投放 agent 安装包并设为分发来源（容器读不到宿主机路径 → 统一走 /packages）：
#   --latest 取 ../wist-agentd/target/package 最新；也可传具体文件/目录
./scripts/import-package.sh --latest --set
#   等价于：cp 到 packages/ + 调管理 API 把来源设为 /packages/<文件名>

# 改了证书/配置后，必须**重启网关容器**才生效（`up -d` 不会因挂载文件变化而重建）：
docker compose --project-directory . -f sys/docker-compose.yml restart gateway
```

> 域名 / 端口改 `sys/setting/vars.yml`（客户覆盖写 `values/value.yml`），再重跑 `gops sys update && gops sys localize`，最后重启网关容器。
>
> **身份模型（CA 签叶）**：`scripts/init-gateway.sh` 建一张**网关 CA**（`state/gateway-ca.{crt,key}.pem`），网关**叶证书由它签发**，agent 的信任锚 = **CA 根**（配置 `agent.trust_bundle_file = state/gateway-ca.crt.pem`）。于是**换域名 / 续期 / 换 SAN 只重签叶证书，锚不变、agent 无感**。
> **CA 私钥不可再生**：`state/gateway-ca.key.pem` 丢了 = 换锚 = **全队 agent 重装**，务必备份（参见「备份」）。

### B. 容器自动初始化（零配置）

bootstrap 镜像首次启动会自己生成 config + 自签证书 + 签名密钥，并把 `listen_addr` 改成 `0.0.0.0:3000`：

```bash
cd ../wist-gateway/docker
docker build -t wist-gateway:latest -f Dockerfile .
docker build -t wist-gateway:bootstrap -f Dockerfile.bootstrap .

# 把 compose 里 gateway 的 image 改成 wist-gateway:bootstrap（本地联调用），然后
cd ../../wist-gateway-stack
gops sys update && gops sys localize
gops sys start
```

生成物落在挂载卷 `configs/gateway/` 里，所以能复用；**不挂卷就会每次重启换一套**（新证书 + 新 admin token + 新签名密钥，已发出的安装命令和 agent 凭据全部失效）。

### 起停与排查

```bash
gops sys status       # 容器状态
gops sys stop         # 停
gops sys uninstall    # 停并删容器（不删卷）
gops sys diagnose     # 渲染后的 compose 配置：排查变量/端口/挂载
```

### 起来之后

- 前端入口：`https://<host>:8443`（nginx 终止 TLS，证书是页面自己的；首访浏览器会提示自签不受信）
- 网关 API：`https://<host>:3000`

## 开发态（本地二进制）

```bash
# 唯一入口：构建一次 → VictoriaMetrics/wparse/web 后台 → gateway 前台（Ctrl+C 停）
./dev/svc.sh start
./dev/svc.sh start --dry-run     # 先看会起哪些/跳过哪些（不启动）
./dev/svc.sh status              # 看四个组件当前状态
./dev/svc.sh stop                # 逆序停全栈

# 只操作某个组件（组件：vm | wparse | web | gateway）
./dev/svc.sh start web           # 只重启前端（gateway 已在跑时）
./dev/svc.sh stop gateway

# 按需一次性工具（不属于 start 流程）
./dev/setup-domain.sh <域名>     # 换域名（改配置 + 重签证书；改完需重启 gateway）
./dev/re-enroll.sh               # 把本机 wist-agentd 重新注册到网关（需 gateway 已在跑）
```

> `svc.sh` 与发布态的 `gops sys start|stop|status` 对应：`start` 把 vm/wparse/web 后台常驻拉起
> 且已在跑则跳过，最后把 gateway 跑在前台；退出时后台组件不会一起停，整栈停止用 `./dev/svc.sh stop`。

`svc.sh start gateway` 会自动做这几件事：**启动时 `cargo build` 一次 `wist-gateway` 与 `wist-agentd`**（保证跑的是当前源码，`--no-build` / `SKIP_BUILD=1` 可跳过）；缺配置就调 `wist-gateway init-config` 生成到 `~/.wist-gateway/`；缺 TLS 证书就 `openssl` 签一张叶证书；把 `package_file` 指到本仓库的 `wist-agentd` 二进制；**并把信任锚写进 `[agent] trust_bundle_file`**（跑过 `dev/setup-domain.sh` 就有 `dev-ca.crt.pem`，锚 = CA 根；没有就退回叶证书自身；供 install.sh 内嵌 `--cacert` 用）。

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

1. **网关启动有一组硬要求**（缺失即拒绝启动，`wist-gateway` 的 `AdminConfig::validate`）：`wist-gateway.toml` 本身、TLS 证书与私钥、Ed25519 签名私钥、`agent.package_file` 指向的文件必须存在；`public_base_url` 必须是 `https://`；`admin_api_token` 要满足长度与熵要求。这就是"为什么必须先初始化"。
2. **信任锚走文件，且是 CA 根**。配置用 `agent.trust_bundle_file = state/gateway-ca.crt.pem`（相对配置目录），由 `scripts/init-gateway.sh` 生成；网关启动时读该文件，并把它下发给 agent（写进 `install.sh` / `agentd.toml`）。旧的 `agent.trust_bundle = """..."""` 内联写法已移除。
3. **叶证书必须带 `basicConstraints=CA:FALSE`（叶形态）、且由网关 CA 签**。`openssl req -x509` 的旧默认会打 `CA:TRUE`，rustls/webpki 会以 `CaUsedAsEndEntity` 拒收；`scripts/init-gateway.sh` 生成的叶证书是 `CA:FALSE` + `serverAuth`，并由网关 CA 签发。**轮换叶证书（换域名 / 续期）是安全的**——锚 = CA 根不变，agent 无感；只有当**锚本身**变了（换 CA / 删掉 `gateway-ca.*` 重生成）才需要**重跑安装**（仅重新注册不刷新锚）。
4. **改证书/配置后要重启网关容器**：`gops sys start`（`up -d`）**不会**因挂载文件变化而重建容器，网关只在**启动时**读 `wist-gateway.toml` 与证书。用：`docker compose --project-directory . -f sys/docker-compose.yml restart gateway`。
5. **镜像 tag 是浮动 `:latest`**。同一份 compose 在不同时间拉到的镜像可能不同，升级也对不齐；生产建议钉到固定版本（必要时加 `@sha256:` 摘要），做法就是改 `sys/docker-compose.yml` 里 `gateway` / `web` 的 `image`。
6. **容器读不到宿主路径**（设置安装包来源时最常见）。网关对**以 `/` 开头的来源**是在**它自己的**文件系统里 `fs::read`；compose 下只有被挂进来的目录可见。所以「本地来源」只能是**容器内路径**：`/packages/<文件名>`（投放目录，见 `scripts/import-package.sh`）或 `/config/<文件名>`（配置目录），否则报 `failed to read package from <宿主路径>: No such file or directory`（界面表现为 502）。拉取成功后网关会把包缓存到 `configs/gateway/state/install-package/`（在挂载卷里，可备份）。
   > 提醒：**别删 `packages/` 目录本身**（容器正挂载它）——删了会让挂载失效、容器内 `/packages` 直接消失；重建容器才恢复（`docker compose --project-directory . -f sys/docker-compose.yml up -d --force-recreate gateway`）。
