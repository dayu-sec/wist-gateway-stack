#!/usr/bin/env bash
# 嵌套挂载检查（被 `dev/check-compose-mounts.sh` 与 `scripts/lib/local-gates.sh` 共用）。
#
# 为什么需要这一层：`docker compose config` 与 `docker compose create` 都**不验证挂载点能不能
# 建起来** —— 只有 `up`（runc 创建容器阶段）才会接触真实挂载。实测（2026-11-14）：
#   `docker compose create` → 退出 0；`docker compose up -d` → `error mounting ... read-only file system`。
#
# 而缺少子挂载点有两种发作方式，只有一种会响：
#   · 父挂载 `:ro` → 在只读挂载里建挂载点 → `create mountpoint ... read-only file system`（硬失败）；
#   · 父挂载 `rw`  → Docker 守护进程以 **root** 建出来 → `gops sys perms --apply` 整片
#     `Operation not permitted`（静默，部署后期才炸）。
# 两者同一个根因：**子挂载点在父挂载的宿主目录里不存在**。
#
# 规则只有一条（嵌套本身不是错，wparse 的 `/data` 就是这么用的）：
#
#   A ⊂ B 且 B 是宿主 bind  ⇒  B 的宿主源 + relpath(A, B) 必须**已经存在**，
#                              且类型与 A 的来源一致（A 挂文件 → 挂载点必须是文件）。
#
# 两种模式：
#   strict   —— 挂载点必须在宿主上真实存在（localize 末尾用：那一刻 init-*.sh 都跑完了）。
#   declared —— 干净 checkout 上用（CI）：`data-plane-run/` 是生成物，必然不存在。
#               此时退一步，要求该路径**在 `scripts/*.sh` 里被声明过**（`mkdir -p`/`touch`
#               的预建清单），否则仍算失败 —— 抓的就是「新加了嵌套挂载，却没有人在
#               localize 阶段预建它」。这是照着 `scripts/init-wparse-admin.sh` 的
#               `NESTED_MOUNTS` / `NESTED_FILES` 那个既有做法定的口径。
#
# 输出：每条问题一行，`service|容器内目标|宿主路径|原因`。空输出 = 通过。
# 退出码：恒 0（调用方按输出是否为空判定；这样两种模式共用一条调用路径）。

# 从 `docker compose config` 的输出里抽挂载：`service|type|source|target|ro|rw`
nested_mount_rows() {
  awk '
    function flush() {
      if (target != "") {
        printf "%s|%s|%s|%s|%s\n", svc, mtype, source, target, (readonly == 1 ? "ro" : "rw")
      }
      mtype = ""; source = ""; target = ""; readonly = 0
    }
    /^services:$/ { in_services = 1; next }
    in_services && /^[A-Za-z_]/ { in_services = 0 }
    in_services && /^  [A-Za-z0-9_.-]+:$/ {
      flush()
      svc = $0; sub(/^  /, "", svc); sub(/:$/, "", svc)
      in_volumes = 0
      next
    }
    in_services && /^    volumes:/ { in_volumes = 1; next }
    in_services && in_volumes && /^    [A-Za-z_]+:/ { in_volumes = 0; next }
    in_volumes && /^      - type: / { flush(); mtype = $3; next }
    in_volumes && /^        source: / { source = substr($0, index($0, "source: ") + 8); next }
    in_volumes && /^        target: / { target = substr($0, index($0, "target: ") + 8); next }
    in_volumes && /^        read_only: true/ { readonly = 1; next }
    END { flush() }
  ' "$1"
}

# 这条路径是否被 `scripts/*.sh` 声明为「localize 阶段预建」（declared 模式用）。
# 匹配 `/work/data` 这种带前导斜杠的后缀：脚本里写的是 `${RUN_DIR}/work/data`。
nested_mount_declared() {
  local root="$1" rel="$2" suffix
  case "$rel" in
    */*) suffix="/${rel#*/}" ;;
    *) suffix="/${rel}" ;;
  esac
  grep -qF -- "$suffix" "$root"/scripts/*.sh 2>/dev/null
}

nested_mount_problems() {
  local root="$1" mode="${2:-strict}" rendered="$3"
  local rows
  rows=$(nested_mount_rows "$rendered") || return 0
  [ -n "$rows" ] || return 0

  local svc mtype source target
  local osvc otype osource otarget oro
  local host rel

  while IFS='|' read -r svc mtype source target _; do
    [ -n "$target" ] || continue
    while IFS='|' read -r osvc otype osource otarget oro; do
      [ "$svc" = "$osvc" ] || continue
      [ "$otype" = "bind" ] || continue
      [ "$target" = "$otarget" ] && continue
      case "$target" in
        "${otarget%/}"/*) ;;
        *) continue ;;
      esac

      # 子挂载点在父挂载宿主源里的落点
      host="${osource%/}/${target#"${otarget%/}/"}"
      if [ -e "$host" ]; then
        # 类型必须对得上：挂文件不能落在目录上（Docker 会报 not a directory）。
        if [ "$mtype" = "bind" ] && [ -f "$source" ] && [ ! -f "$host" ]; then
          printf '%s|%s|%s|挂载点类型不符：源是文件，宿主落点不是普通文件\n' \
            "$svc" "$target" "$host"
        fi
        if [ "$mtype" = "volume" ] && [ ! -d "$host" ]; then
          printf '%s|%s|%s|挂载点类型不符：命名卷需要目录\n' "$svc" "$target" "$host"
        fi
        continue
      fi

      rel="${host#"$root"/}"
      if [ "$mode" = "declared" ] && nested_mount_declared "$root" "$rel"; then
        continue
      fi
      if [ "$oro" = "ro" ]; then
        printf '%s|%s|%s|宿主上不存在（父挂载是 :ro → Docker 建不出挂载点，容器直接起不来）\n' \
          "$svc" "$target" "$host"
      else
        printf '%s|%s|%s|宿主上不存在（父挂载可写 → Docker 会以 root 建，随后 perms --apply 整片失败）\n' \
          "$svc" "$target" "$host"
      fi
    done <<<"$rows"
  done <<<"$rows"
}
