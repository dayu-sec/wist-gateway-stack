# wist-gateway-stack

`wist-gateway`（控制面）+ `wist-gateway-web`（前端）+ `WarpParse`（数据平台）+ 观测的一站式编排。

本仓**只做编排**：网关的镜像/二进制制品来自 [`wist-gateway`](https://github.com/dayu-sec/wist-gateway) 仓的 release 流水线，这里引用它们并负责把它们连起来跑。

## 两种运行方式

- **发布态**：Docker 编排（gops 系统，`kind: docker-compose`），`gops sys start` 拉起整个栈 —— 变量定义与本地化见「发布态」。
- **开发态**：不依赖 Docker，用本地编译的二进制直接跑（`sysrun/`）。

两者共享**同一份 wparse 业务配置**（`sysrun/data-plane/`），环境差异（VictoriaMetrics 地址）通过 `WPARSE_VM_ENDPOINT` 注入，不产生两份配置漂移。

## 组件

| 服务 | 作用 | 端口（宿主:容器） | 镜像来源 |
|---|---|---|---|
| `gateway` | 控制面后端（HTTPS API，rustls） | `3000:3000` | `dy-sec.tencentcloudcr.com/cloud/wist-gateway` |
| `web` | 前端入口（nginx，静态 + `/api` 反代） | `8443:80` | `dy-sec.tencentcloudcr.com/cloud/wist-gateway-web` |
| `wparse` | 数据平台 ELT 引擎 | 无对外端口 | `ghcr.io/wp-labs/warp-parse` |
| `victoria-metrics` | 指标存储 | `18429:8428` | `victoriametrics/victoria-metrics` |

> **镜像两处源**：两个发布流水线都双推 —— `ghcr.io/dayu-sec/*`（境外）与 `dy-sec.tencentcloudcr.com/cloud/*`（腾讯云 TCR，国内快）。compose 里的镜像源与 tag 都是变量，定义在 `sys/setting/vars.yml`（默认 TCR）；改源或钉版本改那里，或在该系统的 `values/value.yml` 做客户覆盖，再 `gops sys update && gops sys localize` 重新生成 `.env`。

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
  sysrun/                   # 开发态：本地二进制 + wparse 工程
    start.sh                # 控制面入口（gateway + web）
    start-vm.sh / stop-vm.sh        # 仅启/停 VictoriaMetrics（走 Docker）
    re-enroll.sh            # 重注册本机 wist-agentd
    bin/                    # wparse 本地二进制
    data-plane/             # wparse 工程（唯一源）
      conf/ connectors/ topology/ models/
      start-wparse.sh / stop-wparse.sh
  configs/                  # 运行期配置
    gateway/                # 发布态：wist-gateway.toml + state/（证书/密钥/store）
    web/nginx.conf          # 发布态：前端站点配置（静态 + /api 反代）
  .github/workflows/release.yml     # 打包发布（见「制品包」）
  README.md
```

> **数据目录**：开发态（`sysrun/start.sh`）的持久数据落在 `~/.wist-gateway/`（`wist-gateway.toml` + `state/`：store / TLS / 签名密钥），与运行期临时目录分离，清 `.run` 不会丢 agents 注册表。发布态通过 `docker-compose.yml` 挂载 `configs/gateway/`。

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

compose 还挂这两个路径，缺任何一个都起不来：

1. `configs/gateway/` —— 网关配置与密钥，用初始化脚本生成（A 或 B，见下）。
2. `configs/web/nginx.conf` —— 前端站点配置。它需要做到：托管前端静态产物、SPA 深链回退到 `index.html`、把 `/api` 反代到 `gateway:3000`。注意网关那侧是**自签 HTTPS**，反代过去要么关掉证书校验、要么把这个自签证书配成可信，否则 502。

### A. 宿主机显式初始化（推荐生产）

```bash
# 生成 config + Ed25519 签名密钥 + 自签 TLS 证书到 configs/gateway/
../wist-gateway/docker/init-gateway.sh configs/gateway

# 按部署环境改 configs/gateway/wist-gateway.toml：
#   listen_addr        → 0.0.0.0:3000（容器内必须监听 0.0.0.0）
#   public_base_url    → 真实对外地址，且 host 要落在 TLS 证书 SAN 内
#   victoria_metrics_url → http://victoria-metrics:8428
#   agent.package_file → 必须是容器内存在的路径（见下方「网关启动的硬要求」）
#   agent.trust_bundle → 必须是真实 CA PEM（见下方「已知坑」）

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
# 1. VictoriaMetrics（第三方依赖，无本地二进制，用 Docker 起）
./sysrun/start-vm.sh

# 2. wparse 数据平台（默认 VM 端点 http://127.0.0.1:18429）
./sysrun/data-plane/start-wparse.sh
WPARSE_VM_ENDPOINT=http://127.0.0.1:18429 ./sysrun/data-plane/start-wparse.sh   # 显式覆盖

# 3. 控制面两件套：gateway(https://127.0.0.1:3000) + web(5174)
./sysrun/start.sh
SKIP_WEB=1 ./sysrun/start.sh     # 只要后端

# 4. 可选：把本机 wist-agentd 重新注册到网关
./sysrun/re-enroll.sh
```

`sysrun/start.sh` 会自动做这几件事：缺配置就调 `wist-gateway init-config` 生成到 `~/.wist-gateway/`；缺 TLS 证书就 `openssl` 自签一张；把 `package_file` 指到本仓库的 `wist-agentd` 二进制（会自动 `cargo build`）；**并把那张自签证书回填进 `trust_bundle`**（供 install.sh 内嵌 `--cacert` 用）。

前置：本地有 Rust 工具链（会按需 `cargo build` `wist-gateway` / `wist-agentd`）、`wist-gateway-web/node_modules`（先 `npm install`）、`sysrun/bin/` 里有 wparse 二进制。日志：`/tmp/wist-gateway-server.log`、`/tmp/wist-gateway-web.log`。

## 制品包（发布）

`.github/workflows/release.yml` 在 `v*.*.*` 标签上打包并发布：

```bash
wist-gateway-stack-<tag>.tar.gz
wist-gateway-stack-<tag>/
  ├── docker-compose.yml
  └── sysrun/            # 脚本 + data-plane 工程（conf/connectors/models/topology）
```

用 `git archive` 出包，只收 git 跟踪的内容，所以 `sysrun/bin/`（约 92M 二进制）和 `data-plane/{data,.run}/`（运行数据）天然不入包。

包里**不含 `configs/`**：`configs/gateway/` 要在目标机现场生成（见「发布态 A/B」），`configs/web/nginx.conf` 也要自己准备。也就是说下载解压后还差这一步初始化。

## 环境接线

wparse 里指向 VictoriaMetrics 的端点用 `${WPARSE_VM_ENDPOINT}` 占位，由运行环境注入：

- 开发态：`start-wparse.sh` 默认 `http://127.0.0.1:18429`。
- 发布态：compose 注入 `http://victoria-metrics:8428`。

## 已知坑

1. **网关启动有一组硬要求**（缺失即拒绝启动，`wist-gateway` 的 `AdminConfig::validate`）：`wist-gateway.toml` 本身、TLS 证书与私钥、Ed25519 签名私钥、`agent.package_file` 指向的文件必须存在；`public_base_url` 必须是 `https://`；`admin_api_token` 要满足长度与熵要求。这就是"为什么必须先初始化"。
2. **发布态没有人回填 `trust_bundle`**。配置模板里它是占位串 `internal-ca-stub`，只有开发态的 `sysrun/start.sh` 会把自签证书写回去。Docker 路径下必须手动把 `configs/gateway/wist-gateway.toml` 的 `agent.trust_bundle` 改成真实 CA PEM（一段 `-----BEGIN CERTIFICATE-----...`），否则 install.sh 内嵌给 `curl --cacert` 的不是证书，agent 安装会失败。
3. **镜像 tag 是浮动 `:latest`**。同一份 compose 在不同时间拉到的镜像可能不同，升级也对不齐；生产建议钉到固定版本（必要时加 `@sha256:` 摘要），做法就是改 `docker-compose.yml` 里 `gateway` / `web` 的 `image`。
