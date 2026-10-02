#!/usr/bin/env bash
# 把宿主侧目录/文件的**属主、属组、权限**对齐到容器内运行身份 —— 让「容器要读写」与「部署账号要维护
# （改配置 / 跑备份恢复）」两种需求同时成立，且**不依赖这些目录是谁创建的**。
#
# 为什么需要它：
#   网关与数据面**固定以 uid:gid 999:999 运行**（镜像内如此，compose 里也显式钉死）。bind 挂载在
#   Linux 上**不改变属主**（宿主是谁，容器里就是谁），于是两种稳定故障：
#     · data-plane-run/{data,.run} 属主是 root/部署账号且 755 → 容器写不出锁文件
#       （flock: cannot open lock file /data/.run/.wparse.lock: Permission denied）→ wparse 以 75 退出、无限重启；
#     · configs/gateway/state/*.pem 是 600 且属主不是 999 → 容器读不到签名私钥 / CA
#       （failed to read install script signing key ...: Permission denied）→ 网关拒绝启动。
#   更麻烦的是：Docker 在 `up` 时会**自行**把缺失的 bind 源目录建成 root:root 755 ——
#   所以「属主取决于谁先创建」，只能在 `up` **之前**显式对齐。
#
# 模型（一处定义，改这里就够）：
#   · 属主 = 执行部署的那个账号（取 SUDO_UID/SUDO_GID，未提权时取 id）—— 它负责改配置、跑备份/恢复；
#   · 属组 = 容器 gid（默认 999）—— 容器进程天然在这个组里；
#   · **需要容器写**的目录 2770（组可写 + **setgid**：目录里新建的文件/目录自动继承该组）；
#     **容器只读**的目录 2755（组可读可进入；web 容器是 root，本不需要属组）；
#   · 私钥与含密钥的配置 640（属组可读）。
#   于是：容器读写自如；部署账号（属主）读写自如 → **备份/恢复不需要提权**；
#   别的宿主账号连目录都进不去（2770），私钥也没有放宽到全局。
#
# 用法：
#   ./scripts/align-host-perms.sh [系统根]      # 缺权限时给出一行命令（免密 sudo 可用时自动提权重跑）
#   sudo ./scripts/align-host-perms.sh          # 等价，但会保留属主为调用账号（读 SUDO_UID/SUDO_GID）
#
# 幂等：已是目标状态就**什么都不做、也不需要任何权限**（所以日常 `gops sys localize` 不会再要 sudo；
# 只有目录/文件确实需要修正时才要提权）。
#
# 环境：CONTAINER_GID（默认 999；与 compose 里 gateway/wparse 的 user: 保持一致）
set -euo pipefail

ROOT="${1:-.}"
CONTAINER_GID="${CONTAINER_GID:-999}"

cd "${ROOT}"
ROOT="$(pwd)"

note() { echo "  $*"; }
die() { echo "错误：$*" >&2; exit 1; }

# 非 Linux 直接跳过：OrbStack / Docker Desktop 的 bind 挂载不校验属主，属主对齐在这里没有意义
# （这也是「macOS 上一直好好的、上 Linux 才炸」的原因）。
if [[ "$(uname -s)" != "Linux" ]]; then
  note "跳过宿主属主对齐（非 Linux：bind 挂载不校验属主，容器照样读写）"
  exit 0
fi

OWNER_UID="${SUDO_UID:-$(id -u)}"
OWNER_GID="${SUDO_GID:-$(id -g)}"
[[ "${CONTAINER_GID}" =~ ^[0-9]+$ ]] ||
  die "CONTAINER_GID 必须是数字 gid（收到 '${CONTAINER_GID}'）；它要与 compose 里 gateway/wparse 的 user: 一致"

# 目标目录：<相对路径>:<权限>（组统一为 CONTAINER_GID）。
#   data-plane-run/*：wparse 写运行态与锁；packages：安装包投放目录（容器只读挂载，部署账号写入）；
#   configs/*：整套现场态（网关读写 store 库/日志、前端渲染产物与页面证书）——全部归部署账号，
#     免得 Docker 先建出 root 属主的目录后部署账号自己都写不动。
#   需要容器写的目录 2770（组可写 + setgid）；容器只读的 2755（web 容器是 root，不需要属组）。
# 边界：只对齐**挂载根与私钥**，不递归内容树 —— `configs/gateway/knowledge/`、`packages/` 里的
#   文件由打包/投放侧保证可读（644/755），递归 chmod 一个内容树既不安全也没必要。
TARGET_DIRS=(
  "data-plane-run:2755"
  "data-plane-run/data:2770"
  "data-plane-run/.run:2770"
  "packages:2770"
  "configs:2755"
  "configs/gateway:2770"
  "configs/gateway/state:2770"
  "configs/web:2755"
  "configs/web/tls:2755"
)
# 目标文件（**存在才处理**，不新建）：
#   state/*.pem        —— 容器要读（CA / 叶 / 签名私钥）；600 会让容器读不到，故 640。
#   wist-gateway.toml  —— 容器要读，且含 admin token，故 640（不是 644）。
#   注：`wist-gateway.value.json` 是**渲染源**，容器不读它，保持 init-gateway 的 600，这里不动。
TARGET_FILES=(configs/gateway/state/*.pem configs/gateway/wist-gateway.toml)
TARGET_FILE_MODE=640

dir_mode_of() {
  local rel="$1" spec
  for spec in "${TARGET_DIRS[@]}"; do
    if [[ "${spec%%:*}" == "${rel}" ]]; then
      printf '%s' "${spec##*:}"
      return 0
    fi
  done
  printf '755'
}

# 现状：`属主:属组:权限`；不存在时给「缺失」（GNU stat 的 %a 含 setuid/setgid/sticky，正是要比对的）
state_of() {
  if [[ -e "$1" ]]; then
    stat -c '%u:%g:%a' "$1"
  else
    printf '缺失'
  fi
}

# ── 1) 先探测（只 stat，不写盘）──
dirs_todo=()
for spec in "${TARGET_DIRS[@]}"; do
  rel="${spec%%:*}"; mode="${spec##*:}"
  [[ "$(state_of "${rel}")" == "${OWNER_UID}:${CONTAINER_GID}:${mode}" ]] || dirs_todo+=("${rel}")
done

files_todo=()
for f in "${TARGET_FILES[@]}"; do
  [[ -e "${f}" ]] || continue # glob 不匹配时是字面量，跳过
  [[ -f "${f}" ]] || { echo "  跳过 ${f}（存在但不是普通文件）" >&2; continue; }
  [[ "$(state_of "${f}")" == "${OWNER_UID}:${CONTAINER_GID}:${TARGET_FILE_MODE}" ]] || files_todo+=("${f}")
done

if [[ ${#dirs_todo[@]} -eq 0 && ${#files_todo[@]} -eq 0 ]]; then
  note "宿主属主/权限已对齐（属主 ${OWNER_UID}、属组 ${CONTAINER_GID}、目录 2770/2755、私钥 ${TARGET_FILE_MODE}），无需改动"
  exit 0
fi

# ── 2) 要改：确认有权限，否则自动提权重跑（仅当免密 sudo 可用），再否则给出那一行命令 ──
can_align=1
if [[ "$(id -u)" -ne 0 ]]; then
  # 非 root：属主要保持是自己，且目标属组必须是自己所在的组，chown/chgrp 才被允许
  can_align=0
  if [[ "${OWNER_UID}" == "$(id -u)" ]]; then
    case " $(id -G) " in
      *" ${CONTAINER_GID} "*) can_align=1 ;;
    esac
  fi
fi

if [[ "${can_align}" != "1" ]]; then
  if [[ -z "${ALIGN_NO_SUDO:-}" ]] && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    note "需要提权（改属主/属组），检测到免密 sudo → 以 sudo 重跑（属主仍保持为 ${OWNER_UID}:${OWNER_GID}）"
    # 重跑失败（sudo 策略不允许 / chown 失败）不能直接死：下面还要把“该手工跑什么”打出来
    sudo -E "$0" "$@" && exit 0
    echo "  （sudo 重跑未成功，继续给出可执行命令）" >&2
  fi
  # 两个数组里至少一个非空（上面已就空则退出），但仍然分开判断，避免空数组在 set -u 下展开
  todo_show=()
  [[ ${#dirs_todo[@]} -gt 0 ]] && todo_show+=("${dirs_todo[@]}")
  [[ ${#files_todo[@]} -gt 0 ]] && todo_show+=("${files_todo[@]}")
  echo "需要修正但权限不足（目标：属主 ${OWNER_UID}、属组 ${CONTAINER_GID}）：" >&2
  for p in "${todo_show[@]}"; do
    printf '  - %s（现为 %s）\n' "${p}" "$(state_of "${p}")" >&2
  done
  echo "请执行（只做这一步，属主仍是当前账号）：" >&2
  echo "  sudo $0 ${ROOT}" >&2
  exit 1
fi

# ── 3) 应用 ──
if [[ "${OWNER_UID}" == "0" ]]; then
  echo "  警告：以 root 身份部署 —— 栈内文件会变成 root 属主，之后用普通账号跑 localize / 备份会写不动。" >&2
  echo "        建议改用普通账号（已加入 docker 组）执行部署。" >&2
fi

for rel in "${dirs_todo[@]}"; do
  mode="$(dir_mode_of "${rel}")"
  before="$(state_of "${rel}")"
  # 同名**文件**（例如把挂载源写成了文件、或 Docker 建错）会让 mkdir -p 报一句难读的错，先点破
  [[ -e "${rel}" && ! -d "${rel}" ]] &&
    die "${rel} 已存在但不是目录（是文件/符号链接？）—— 删掉它再跑，别让容器挂载点落在文件上"
  mkdir -p "${rel}"
  chown "${OWNER_UID}:${CONTAINER_GID}" "${rel}"
  chmod "${mode}" "${rel}"
  printf '  目录 %s：%s → %s:%s:%s\n' "${rel}" "${before}" "${OWNER_UID}" "${CONTAINER_GID}" "${mode}"
done

for f in "${files_todo[@]}"; do
  before="$(state_of "${f}")"
  chown "${OWNER_UID}:${CONTAINER_GID}" "${f}"
  chmod "${TARGET_FILE_MODE}" "${f}"
  printf '  文件 %s：%s → %s:%s:%s\n' "${f}" "${before}" "${OWNER_UID}" "${CONTAINER_GID}" "${TARGET_FILE_MODE}"
done

note "宿主属主/权限对齐完成：属主 ${OWNER_UID}、属组 ${CONTAINER_GID}（容器内 gateway/wparse 的运行身份）"
