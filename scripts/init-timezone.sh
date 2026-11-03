#!/usr/bin/env bash
# 把**宿主当前时区**的数据文件复制进栈内，供容器以 `TZ=:<file>` 读取。
#
# 为什么不在 compose 里直接挂宿主的 `/etc/localtime` / `/usr/share/zoneinfo`：
#   * 本栈的宿主权限由 `gops sys perms` **从 compose 派生**（只读文件挂载 → `0640`）。
#     挂宿主系统文件 = 让一次部署去改 `/etc/localtime` 的权限（去掉 other 读），
#     这个副作用会波及机器上所有程序，不能接受；它们还是「系统根之外」的 bind source，
#     需要额外进 `perms.allow_external`。
#   * 只设 `TZ=Asia/Shanghai` 又要求**镜像自带 tzdata**：wparse / web 是上游镜像，
#     无法假设。更糟的是「TZ 写了名字、镜像却没有 zoneinfo」时，glibc 会回落到 UTC ——
#     看起来设了、其实没生效（正是线上这个 bug 的形态）。
#
# 所以：复制一份 zone 数据进栈内（`configs/runtime/tz`，已在 .gitignore 覆盖范围内），
# 容器用 `TZ=:/etc/tz-runtime/localtime` 指向它 —— 不碰宿主系统文件，也不依赖镜像 tzdata。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TZ_NAME="${TZ:-Asia/Shanghai}"
DEST_DIR="$ROOT/configs/runtime/tz"
DEST="$DEST_DIR/localtime"

mkdir -p "$DEST_DIR"

# 优先按变量名取（`TZ` 是**意图**，宿主编译/安装了 tzdata 时它最准）；
# 退而取当前生效的 `/etc/localtime`（保证容器里显示的与宿主一致）。
if [ -f "/usr/share/zoneinfo/$TZ_NAME" ]; then
  SRC="/usr/share/zoneinfo/$TZ_NAME"
elif [ -e /etc/localtime ]; then
  SRC="/etc/localtime"
else
  echo "错误：找不到时区数据：/usr/share/zoneinfo/${TZ_NAME} 与 /etc/localtime 都不存在。" >&2
  echo "     处置：在 values/value.yml 里把 TZ 改成宿主实际使用的时区，或给宿主装 tzdata。" >&2
  exit 1
fi

if [ -f "$DEST" ] && cmp -s "$SRC" "$DEST"; then
  echo "时区数据已是最新：${TZ_NAME}"
  exit 0
fi

# `-L`：`/etc/localtime` 在多数发行版上是符号链接，必须解引用后复制内容
# （容器里那份要是**文件**，不能是悬空链接）。
cp -Lf "$SRC" "$DEST"
echo "时区数据：${TZ_NAME}（来自 ${SRC}）→ configs/runtime/tz/localtime"
