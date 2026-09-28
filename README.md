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
| `gateway` | 控制面后端（HTTPS API，rustls） | `3000:3000` | `dy-sec.tencentcloudcr.com/cloud/wist-gateway` |
| `web` | 前端入口（nginx，静态 + `/api` 反代） | `8443:80` | `dy-sec.tencentcloudcr.com/cloud/wist-gateway-web` |
| `wparse` | 数据平台 ELT 引擎 | 无对外端口 | 上游 `ghcr.io/wp-labs/warp-parse`（变量 `WPARSE_IMAGE`） |
| `victoria-metrics` | 指标存储 | `18429:8428` | `victoriametrics/victoria-metrics` |

> **镜像两处源**：两个发布流水线都双推 —— `ghcr.io/dayu-sec/*`（境外）与 `dy-sec.tencentcloudcr.com/cloud/*`（腾讯云 TCR，国内快）。compose 里的镜像源与 tag 都是变量，定义在 `sys/setting/vars.yml`（默认 TCR）；改源或钉版本改那里，或在该系统的 `values/value.yml` 做客户覆盖，再 `gops sys update && gops sys localize` 重新生成 `.env`。
>
> **wparse 不同**：它是**上游镜像**（默认 `ghcr.io/wp-labs/warp-parse`，**没有 TCR 镜像**）—— 拉不到 ghcr.io 的环境把 `WPARSE_IMAGE` 指到内网镜像仓库（先把同版本镜像同步过去）即可，`WPARSE_TAG` 不变。它还与 `data-plane/` **强耦合**：引擎版本一变，`conf/connectors/models/topology` 的 schema 可能跟着变，所以 `WPARSE_TAG` 必须钉版本（当前 `0.26.0-beta`，与开发态 `dev/bin/wparse` 同 commit），升级时**连同 `data-plane/` 一起升**。
>
> **挂载约定**（镜像里 `/data` 属非 root 用户 `wparse`(uid 999)）：配置从 `data-plane/` 按目录**只读**挂到 `/data/<name>`（`WPARSE_WORK_DIR`）；运行态**直接挂到 `/data` 的两个子路径**——`${WPARSE_RUN_DATA} → /data/data`、`${WPARSE_RUN_STATE} → /data/.run`。**不挂 `/data` 这一整根**：把运行目录挂成 `/data`、再把配置嵌进去，会让 Docker 在宿主运行目录里建出一堆空白挂载点目录；直接挂两个子路径后，挂载点都建在容器层，宿主目录保持干净。**Linux 部署要保证这两个目录对 uid 999 可写**（`chown -R 999:999 data-plane-run`；OrbStack 会自动放行，Linux 不会）。
>
> **单实例保障**（同一 work root 只能一个引擎；引擎自身没有这层保护）：容器 entrypoint 先用
> `flock --verbose -n -E 75 -F /data/.run/.wparse.lock` 持锁，再把引擎交给 PID 1（`-F` 不 fork，所以
> `docker stop` 的 SIGTERM 直达引擎、能优雅退出；拿不到锁时日志 `flock: failed to get lock`、容器 `Exited (75)`）。
> 开发态 `dev/start-wparse.sh` 用**同一位置**的锁（`<work-root>/.run/.wparse.lock`）并额外用
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

> **端口口径**：网关那侧是 **HTTPS**（`https://<host>:3000`）；前端那侧 `8443:80` 映射到容器内的 nginx `:80`，**是明文 HTTP**（`http://<host>:8443`），要对外提供 HTTPS 得在它前面再挂一层终止。

## 目录

```
wist-gateway-stack/
  docker-compose.yml        # 发布态：Docker 编排（易变量用 ${VAR} 占位）
  sys-prj.yml               # gops 项目描述
  sys/                      # gops 系统定义
    sys_model.yml           # kind: docker-compose（gops sys 据此分发到 docker compose）
    setting/vars.yml        # 系统变量定义（改默认值改这里）
    resolved_vars.yml       # 生成：gops sys update
  data-plane/               # wparse 工程：配置的唯一源（conf/connectors/models/topology；开发态与发布态共用）
    conf/ connectors/ topology/ models/
  data-plane-run/           # 发布态 wparse 运行态根（data/ + .run/ 分别挂到容器 /data/data、/data/.run；不入 git）
  dev/                      # 开发态：本地二进制 + 启停脚本
    start-svc.sh / stop-svc.sh      # 开发态一站式：起/停 VM + wparse + web + gateway
    start-gateway.sh        # 仅启控制面后端 gateway（前台）
    start-web.sh / stop-web.sh      # 仅启/停前端 web
    start-vm.sh / stop-vm.sh        # 仅启/停 VictoriaMetrics（走 Docker）
    start-wparse.sh / stop-wparse.sh   # 仅启/停数据面（工程在 ../data-plane）
    re-enroll.sh            # 重注册本机 wist-agentd
    bin/                    # wparse 本地二进制
  configs/                  # 运行期配置
    gateway/                # 发布态：wist-gateway.toml + state/（证书/密钥/store）
    web/nginx.conf          # 发布态：前端站点配置（静态 + /api 反代）
  .github/workflows/release.yml     # 打包发布（见「制品包」）
  README.md
```

> **数据目录**：开发态（`dev/start-gateway.sh`）的持久数据落在 `~/.wist-gateway/`（`wist-gateway.toml` + `state/`：SQLite 库 / TLS / 签名密钥），与运行期临时目录分离，清 `.run` 不会丢 agents 注册表。发布态通过 `docker-compose.yml` 挂载 `configs/gateway/`。

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

> 顺序不能反：先 `update` 再 `localize`。
> 本栈当前无密钥；将来若需要，compose 里用 `${SEC_xxx}` 占位，由 `gops sys start` 从 `~/.galaxy/sec_value.yml` 注入，不落盘。

### 前置：挂载文件

compose 还挂这两个路径：

1. `configs/gateway/` —— 网关配置与密钥。**仓库不含**，要在目标机现场生成（A 或 B，见下）。
2. `configs/web/nginx.conf` —— 前端站点配置。**仓库已自带，直接用**：托管前端静态产物、SPA 深链回退到 `index.html`、把 `/api` 反代到 `gateway:3000`（网关那侧是**自签 HTTPS**，已关掉证书校验）。

### A. 宿主机显式初始化（推荐生产）

```bash
# 生成 config + Ed25519 签名密钥 + 自签 TLS 证书到 configs/gateway/
../wist-gateway/docker/init-gateway.sh configs/gateway

# 按部署环境改 configs/gateway/wist-gateway.toml：
#   listen_addr        → 0.0.0.0:3000（容器内必须监听 0.0.0.0）
#   public_base_url    → 真实对外地址，且 host 要落在 TLS 证书 SAN 内
#   victoria_metrics_url → http://victoria-metrics:8428
#   agent.package_file → 必须是容器内存在的路径（见下方「网关启动的硬要求」）
#   agent.trust_bundle → 必须是真实证书 PEM（一段 -----BEGIN CERTIFICATE-----…，见下方「已知坑」）

# 变量本地化 + 起服务
gops sys update && gops sys localize
gops sys start
```

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

- 前端入口：`http://<host>:8443`（明文，见上方端口口径）
- 网关 API：`https://<host>:3000`

## 开发态（本地二进制）

```bash
# 一步到位：VictoriaMetrics + wparse + 控制面全起（控制面前台，Ctrl+C 停）
./dev/start-svc.sh
./dev/start-svc.sh --dry-run   # 先看会起哪些/跳过哪些（不启动）

# 或按组件单独起：
# 1. VictoriaMetrics（第三方依赖，无本地二进制，用 Docker 起）
./dev/start-vm.sh / ./dev/stop-vm.sh

# 2. wparse 数据平台（工程在 data-plane/；默认 VM 端点 http://127.0.0.1:18429）
./dev/start-wparse.sh / ./dev/stop-wparse.sh
WPARSE_VM_ENDPOINT=http://127.0.0.1:18429 ./dev/start-wparse.sh   # 显式覆盖

# 3. 控制面：gateway(https://127.0.0.1:3000) / web(5174)
./dev/start-gateway.sh        # 只要后端（前台，Ctrl+C 停）
./dev/start-web.sh            # 只要前端
./dev/stop-web.sh             # 停前端

# 4. 可选：把本机 wist-agentd 重新注册到网关
./dev/re-enroll.sh
```

> `start-svc.sh` 与发布态的 `gops sys start` 对应：它把前 3 步（VM / wparse / web）后台常驻拉起
> 且已在跑则跳过，最后 exec 交接给 `start-gateway.sh` 把 gateway 跑在前台。
> 退出时后台组件不会一起停，整栈停止用 `./dev/stop-svc.sh`。
> 可用 `SKIP_VM=1` / `SKIP_WPARSE=1` / `SKIP_WEB=1` 裁剪。

`dev/start-gateway.sh` 会自动做这几件事：**每次启动都 `cargo build` `wist-gateway` 与 `wist-agentd`**（保证跑的是当前源码，`SKIP_BUILD=1` 可跳过）；缺配置就调 `wist-gateway init-config` 生成到 `~/.wist-gateway/`；缺 TLS 证书就 `openssl` 自签一张；把 `package_file` 指到本仓库的 `wist-agentd` 二进制；**并把那张自签证书回填进 `trust_bundle`**（供 install.sh 内嵌 `--cacert` 用）。

前置：本地有 Rust 工具链（脚本会 `cargo build` `wist-gateway` / `wist-agentd`）、`wist-gateway-web/node_modules`（先 `npm install`）、`dev/bin/` 里有 wparse 二进制。日志：`/tmp/wist-gateway-server.log`、`/tmp/wist-gateway-web.log`。

## 制品包（发布）

`.github/workflows/release.yml` 在 `v*.*.*` 标签上打包并发布：**整仓内容（除 CI 自身的 `.github/`）**。

```bash
wist-gateway-stack-<tag>.tar.gz
  docker-compose.yml          # tar 内容平铺（不带顶层目录）
  sys/ + sys-prj.yml          # gops 系统定义（sys_model、setting/vars.yml、resolved_vars.yml）
  data-plane/                 # wparse 工程（conf/connectors/models/topology）
  dev/                        # 开发态启停脚本（bin/ 不入 git）
  configs/web/nginx.conf      # 前端站点配置（随仓自带）
  _gal/                       # gx 工作流
  version.txt
  README.md / .gitignore
```

> 包内**不要加顶层目录前缀**：`gops` 解包时会自建同名目录（`~/ds-package/<包名>/`），包内再套一层会导致 `prj import` 找不到 `sys/sys_model.yml`。
>
> 包里的变量解析产物 `sys/merged_vars.yml`（`prj import` 缺了会报“系统变量未解析”）：gops 文档标注它**需入库**，所以它随仓库一起进包 —— **改了 `sys/setting/vars.yml` 后要本地跑一次 `gops sys update` 并提交它**，否则包里带的是旧值。CI 里不跑 gops，包内容完全由 `git archive` 决定。

用 `git archive` 出包，只收 git 跟踪的内容 —— `dev/bin/`（约 92M 二进制）、`data-plane/{data,.run}/`、`_gal/.report`、以及 gops 生成物（`.env`、`values/`）都没入 git，天然不入包。

包里**含 `configs/web/nginx.conf`**（前端站点配置随仓走，直接用）**但不含 `configs/gateway/`**：后者要在目标机现场生成（见「发布态 A/B」）。下载解压后还差「生成网关配置」这一步。

## 环境接线

wparse 里指向 VictoriaMetrics 的端点用 `${WPARSE_VM_ENDPOINT}` 占位，由运行环境注入：

- 开发态：`start-wparse.sh` 默认 `http://127.0.0.1:18429`。
- 发布态：compose 注入 `http://victoria-metrics:8428`。

## 已知坑

1. **网关启动有一组硬要求**（缺失即拒绝启动，`wist-gateway` 的 `AdminConfig::validate`）：`wist-gateway.toml` 本身、TLS 证书与私钥、Ed25519 签名私钥、`agent.package_file` 指向的文件必须存在；`public_base_url` 必须是 `https://`；`admin_api_token` 要满足长度与熵要求。这就是"为什么必须先初始化"。
2. **发布态没有人回填 `trust_bundle`**。配置模板里它是占位串 `internal-ca-stub`，只有开发态的 `dev/start-gateway.sh` 会把自签证书写回去。Docker 路径下必须手动把 `configs/gateway/wist-gateway.toml` 的 `agent.trust_bundle` 改成真实证书 PEM（一段 `-----BEGIN CERTIFICATE-----...`），否则 install.sh 内嵌给 `curl --cacert` 的不是证书，agent 安装会失败。填的应当是**网关 `state/admin-tls.crt.pem` 这张自签证书本身**（自签叶证书即可作信任锚，webpki 接受非 CA 作锚），不必额外准备 CA。
3. **网关自签证书必须带 `basicConstraints=CA:FALSE`（叶证书形态）**。`openssl req -x509` 的旧默认会打上 `CA:TRUE`，而 rustls/webpki 会以 `CaUsedAsEndEntity` 拒收它作服务端证书 —— Agent 一侧表现为 TLS 握手失败，日志里是 `error sending request for url (...)`；用 OpenSSL 系客户端（`curl --cacert`）测却会迷惑性地成功。`init-gateway.sh` / `dev/start-gateway.sh` 已改为生成叶证书，并会检测到旧的 `CA:TRUE` 证书后自动重生成；证书一换，Agent 侧内嵌的 `trust_bundle` 即失效，必须**重跑安装**（仅重新注册不会刷新它）。
4. **镜像 tag 是浮动 `:latest`**。同一份 compose 在不同时间拉到的镜像可能不同，升级也对不齐；生产建议钉到固定版本（必要时加 `@sha256:` 摘要），做法就是改 `docker-compose.yml` 里 `gateway` / `web` 的 `image`。
