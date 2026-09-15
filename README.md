# wist-gateway-stack

`wist-gateway` + `wist-gateway-web` + `WarpParse`（数据平台）的一站式编排。

## 两种运行方式

- **开发态**：不依赖 Docker，用本地编译的二进制直接跑（`sysrun/`）。
- **发布态**：Docker 编排，一个 `docker compose up -d` 拉起整个栈（顶层 `docker-compose.yml`）。

两者共享**同一份 wparse 业务配置**（`sysrun/data-plane/`），环境差异（VictoriaMetrics 地址）通过 `WPARSE_VM_ENDPOINT` 环境变量注入，不产生两份配置漂移。

## 组件

| 服务 | 作用 | 端口（宿主:容器） | 镜像来源 |
|---|---|---|---|
| `gateway` | 控制面后端（HTTPS API） | `3000:3000` | `ghcr.io/dayu-sec/wist-gateway` |
| `web` | 前端入口（静态 + `/api` 反代） | `8443:80` | `ghcr.io/dayu-sec/wist-gateway-web` |
| `wparse` | 数据平台 ELT 引擎 | 无对外端口 | `ghcr.io/wp-labs/warp-parse` |
| `victoria-metrics` | 指标存储 | `18429:8428` | `victoriametrics/victoria-metrics` |

只接 `victoria-metrics`，不接 `victoria-logs`、`wp-monitor`。

## 目录

```
wist-gateway-stack/
  docker-compose.yml        # 发布态：Docker 编排
  sysrun/                   # 开发态：本地二进制
    start.sh                # 控制面入口（gateway + web）
    bin/                    # wparse 本地二进制
    data-plane/             # wparse 工程（唯一源）
      conf/ connectors/ topology/ models/ data/
      start-wparse.sh / stop-wparse.sh
    start-vm.sh / stop-vm.sh  # 开发态仅启/停 VictoriaMetrics
  configs/
    gateway/                # 发布态(Docker)：wist-gateway.toml + state/（证书/密钥/store）
  README.md
```

> **数据目录**：开发态(`sysrun/start.sh`) 的持久数据落在 `~/.wist-gateway/`
> （`wist-gateway.toml` + `state/`：store / TLS / 签名密钥），与运行期临时目录分离，
> 清 `.run` 不再丢失 agents 注册表。发布态(Docker) 通过 `docker-compose.yml` 挂载 `configs/gateway/`。

## 开发态（本地二进制）

```bash
# 1. 先起 VictoriaMetrics（第三方依赖，无本地二进制，用 Docker 起）
./sysrun/start-vm.sh

# 2. wparse 数据平台（默认 VM 端点 http://127.0.0.1:18429）
./sysrun/data-plane/start-wparse.sh

# 覆盖 VM 端点
WPARSE_VM_ENDPOINT=http://127.0.0.1:18429 ./sysrun/data-plane/start-wparse.sh
```

## 发布态（Docker）

```bash
docker compose up -d
```

- 前端入口：`https://<host>:8443`
- 网关 API：`https://<host>:3000`

## 初始化（两种方式）

### A. 宿主机显式初始化（推荐生产）

```bash
# 生成 config + 签名密钥 + 自签 TLS 证书到 configs/gateway/
../wist-gateway/docker/init-gateway.sh configs/gateway
# 编辑 configs/gateway/wist-gateway.toml（listen_addr=0.0.0.0:3000、public_base_url、victoria_metrics_url、package_file）
docker compose up -d
```

### B. 容器自动初始化（零配置）

用 bootstrap 镜像，首次启动自动生成 config + 证书 + 密钥：

```bash
cd ../wist-gateway/docker
docker build -t wist-gateway:latest -f Dockerfile .
docker build -t wist-gateway:bootstrap -f Dockerfile.bootstrap .
# 把 compose 里 gateway 的 image 换成 wist-gateway:bootstrap，再 up
cd ../../wist-gateway-stack && docker compose up -d
```

## 环境接线

wparse 里指向 VictoriaMetrics 的端点用 `${WPARSE_VM_ENDPOINT}` 占位，由运行环境注入：

- 开发态：`start-wparse.sh` 默认 `http://127.0.0.1:18429`。
- 发布态：compose 注入 `http://victoria-metrics:8428`。
