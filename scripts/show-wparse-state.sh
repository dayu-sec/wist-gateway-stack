#!/usr/bin/env bash
# 查看 wparse 运行态：remote-models / remote-infra 的克隆信息，以及它们与工作目录是否一致。
#
# 为什么需要它：wparse 的 /data/.run 挂在**命名卷**里（admin token 要求 0600/属主 999，
# 不能和 `gops sys perms` 管理的 bind 挂载混在一起），所以 `data-plane-run/` 下看不到
# `remote-models` / `remote-infra` 的 git 仓库。本脚本统一两种宿主环境的看法：
#   · 容器在跑：一律用 `docker exec` 读（Linux 上 /var/lib/docker 通常只有 root 可读）；
#   · 容器没起：回退到宿主能读到的卷视图（macOS/OrbStack 的 ~/OrbStack/docker/volumes/<卷名>，
#     或 Linux 上有权限时的 `docker volume inspect` Mountpoint）。
#
# “一致”包含两层：
#   1) state（project_remote_state.json 记录的已应用版本）的 revision == 克隆的 HEAD；
#   2) 克隆 HEAD 的内容 == 工作根 `/data` 的对应子目录（models / conf / topology / connectors），
#      逐文件 sha256 比对（不依赖容器里有 git）。
#
# 用法：
#   scripts/show-wparse-state.sh                # 两个克隆 + 与工作目录逐文件比对
#   scripts/show-wparse-state.sh --raw          # 额外打印 project_remote_state.json 原文
#   scripts/show-wparse-state.sh --logs 50      # 额外看最近 50 行发布相关日志
#   scripts/show-wparse-state.sh --copy ./tmp   # 把 project_remote 整个拷出来给 IDE / 宿主 git
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VOLUME="${WPARSE_RUN_VOLUME:-wist-gateway-stack-wparse-run}"
CONTAINER="${WPARSE_CONTAINER:-wist-gateway-stack-wparse}"
RUN_DIR="/data/.run"
WORK_DIR_HOST="${STACK_ROOT}/data-plane-run/work"

HOST_VIEW=""
MOUNTPOINT=""
LOGS=0
COPY_TO=""
RAW=0

note()    { echo "  $*"; }
warn()    { echo "  ⚠ $*" >&2; }
section() { printf '\n== %s\n' "$*"; }

usage() {
  cat <<'EOF'
用法: scripts/show-wparse-state.sh [选项]

查看 wparse 运行态里 remote-models / remote-infra 的克隆信息，
并与工作目录（/data 的 models、conf、topology、connectors）逐文件比对是否一致。

选项:
  --raw          额外打印 project_remote_state.json 原文
  --logs N       额外输出最近 N 行 project_remote / 发布相关日志（N>0 时生效）
  --copy DIR     把 project_remote 整个导出到 DIR（给 IDE / 宿主 git 用）
  -h, --help     显示本帮助

环境变量:
  WPARSE_RUN_VOLUME  运行态卷名（默认 wist-gateway-stack-wparse-run）
  WPARSE_CONTAINER   容器名（默认 wist-gateway-stack-wparse）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw)
      RAW=1; shift ;;
    --logs)
      [[ $# -ge 2 ]] || { echo "--logs 需要一个数字参数" >&2; exit 2; }
      LOGS="$2"; shift 2 ;;
    --copy)
      [[ $# -ge 2 ]] || { echo "--copy 需要一个目标目录" >&2; exit 2; }
      COPY_TO="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    *)
      echo "未知参数：$1（-h 看帮助）" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "错误：需要 docker CLI" >&2; exit 1; }

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || true)" == "true" ]]
}

resolve_paths() {
  local orb="${HOME}/OrbStack/docker/volumes/${VOLUME}"
  if [[ -d "${orb}" ]]; then
    HOST_VIEW="${orb}"
  fi
  MOUNTPOINT="$(docker volume inspect -f '{{.Mountpoint}}' "${VOLUME}" 2>/dev/null || true)"
  if [[ -z "${HOST_VIEW}" && -n "${MOUNTPOINT}" && -r "${MOUNTPOINT}" ]]; then
    HOST_VIEW="${MOUNTPOINT}"
  fi
}

# 读 /data/.run 下的文件：容器优先，其次宿主卷视图。
read_runtime() {
  local rel="$1"
  if container_running; then
    docker exec "${CONTAINER}" cat "${RUN_DIR}/${rel}"
  elif [[ -n "${HOST_VIEW}" ]]; then
    cat "${HOST_VIEW}/${rel}"
  else
    return 1
  fi
}

# 在运行态里执行 sh 片段：$R = project_remote 根，$W = 工作根；额外参数按 $1.. 传入。
runtime_sh() {
  local snippet="$1"
  shift
  if container_running; then
    docker exec "${CONTAINER}" sh -c "R=${RUN_DIR}; W=/data; ${snippet}" wparse-state "$@"
  elif [[ -n "${HOST_VIEW}" ]]; then
    R="${HOST_VIEW}" W="${WORK_DIR_HOST}" sh -c "${snippet}" wparse-state "$@"
  else
    return 1
  fi
}

# project_remote_state.json 里取字段（避免依赖 jq）。
state_field() { # $1=组（models/infra） $2=字段（tag/revision/version）
  printf '%s' "${STATE_JSON}" | tr -d '\n' |
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*{[^}]*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# 主体：远端克隆信息 + 与工作目录的逐文件比对。
REPORT_SNIPPET="$(cat <<'SNIPPET'
MTAG="$1"; MREV="$2"; ITAG="$3"; IREV="$4"

if command -v sha256sum >/dev/null 2>&1; then HASH="sha256sum"
elif command -v shasum >/dev/null 2>&1; then HASH="shasum -a 256"
else HASH="openssl dgst -sha256 -r"
fi
hash_file() { $HASH "$1" | cut -d" " -f1; }
tmpfile() { mktemp "${TMPDIR:-/tmp}/wpstate.XXXXXX"; }

list_tree() { # $1=根目录 $2=子目录；输出 "hash path"
  a=$(tmpfile)
  ( cd "$1" 2>/dev/null && find "$2" -type f 2>/dev/null | LC_ALL=C sort |
      while IFS= read -r f; do printf "%s %s\n" "$(hash_file "$f")" "$f"; done ) > "$a"
  printf "%s" "$a"
}

show_repo() { # $1=仓库目录名 $2=state tag $3=state revision $4..=要比对的子目录
  name="$1"; stag="$2"; srev="$3"; shift 3
  repo="$R/project_remote/$name"
  if [ ! -d "$repo/.git" ]; then
    printf "  %s（缺失：%s）\n" "$name" "$repo"
    return
  fi
  head=$(cat "$repo/.git/HEAD")
  origin=$(sed -n "s/^[[:space:]]*url = //p" "$repo/.git/config" | head -n 1)
  tags=$({ ls "$repo/.git/refs/tags" 2>/dev/null
           sed -n "s/^[0-9a-f]\{40\} refs\/tags\///p" "$repo/.git/packed-refs" 2>/dev/null
         } | sort -u | tr "\n" " ")

  printf "  %s\n" "$name"
  printf "    origin : %s\n" "$origin"
  printf "    state  : %s @ %s\n" "${stag:--}" "${srev:--}"
  if [ -n "$srev" ] && [ "$head" = "$srev" ]; then
    printf "    HEAD   : %s（与 state 一致）\n" "$head"
    st_ok=1
  else
    printf "    HEAD   : %s（⚠ 与 state 不一致）\n" "$head"
    st_ok=0
  fi
  printf "    tags   : %s\n" "$tags"

  printf "    工作目录 %s：\n" "$W"
  wk_ok=1
  for sub in "$@"; do
    a=$(list_tree "$repo" "$sub")
    b=$(list_tree "$W" "$sub")
    n=$(wc -l < "$a" | tr -d " ")
    if cmp -s "$a" "$b"; then
      printf "      %-12s 一致（%s 个文件）\n" "$sub" "$n"
    else
      wk_ok=0
      report=$(awk '
        FNR==NR { h[$2]=$1; next }
        { h2[$2]=$1 }
        END {
          for (p in h) {
            if (p in h2) { if (h[p] != h2[p]) print "changed    " p }
            else print "only-clone " p
          }
          for (p in h2) if (!(p in h)) print "only-work  " p
        }' "$a" "$b" | LC_ALL=C sort)
      cnt=$(printf "%s\n" "$report" | grep -c .)
      printf "      %-12s 有差异（%s 处）：\n" "$sub" "$cnt"
      printf "%s\n" "$report" | head -n 20 | sed "s/^/        /"
      [ "$cnt" -gt 20 ] && printf "        …… 仅列前 20 处\n"
    fi
    rm -f "$a" "$b"
  done

  if [ "$st_ok" = 1 ] && [ "$wk_ok" = 1 ]; then
    printf "    结论   : 一致\n"
  else
    printf "    结论   : 有差异\n"
  fi
}

show_repo remote-models "$MTAG" "$MREV" models
printf "\n"
show_repo remote-infra "$ITAG" "$IREV" conf topology connectors
SNIPPET
)"

show_logs() {
  local n="$1"
  [[ "${n}" -gt 0 ]] || return 0
  local snippet
  snippet='tail -n 2000 /data/data/logs/wparse.log 2>/dev/null | grep -E "project remote sync|admin api project update|fetch remote tags" | tail -n '"${n}"
  if container_running; then
    docker exec "${CONTAINER}" sh -c "${snippet}"
  else
    warn "容器未运行，跳过日志"
  fi
}

copy_out() {
  local dest="$1"
  mkdir -p "${dest}"
  if container_running; then
    docker cp "${CONTAINER}:${RUN_DIR}/project_remote" "${dest}/"
  elif [[ -n "${HOST_VIEW}" ]]; then
    cp -a "${HOST_VIEW}/project_remote" "${dest}/"
  else
    echo "错误：容器未运行且宿主无权访问卷，无法导出" >&2
    return 1
  fi
  local root="${dest%/}/project_remote"
  printf '\n'
  note "已导出：${root}"
  note "宿主 git 查看（属主是容器用户 999，需加 safe.directory）："
  note "  git -c safe.directory='*' -C ${root}/remote-models log --oneline -5"
}

resolve_paths

STATE_JSON="$(read_runtime project_remote_state.json 2>/dev/null || true)"
MTAG="$(state_field models tag)"
MREV="$(state_field models revision)"
ITAG="$(state_field infra tag)"
IREV="$(state_field infra revision)"

section "位置"
note "卷名     : ${VOLUME}"
if [[ -n "${MOUNTPOINT}" ]]; then
  note "卷路径   : ${MOUNTPOINT}（Docker 引擎内）"
fi
if [[ -n "${HOST_VIEW}" ]]; then
  note "宿主视图 : ${HOST_VIEW}"
else
  note "宿主视图 : 不可读（Linux 通常需 sudo；脚本会用 docker exec 读取）"
fi
note "工作根   : ${WORK_DIR_HOST}"
note "容器     : ${CONTAINER}（运行中：$(container_running && echo 是 || echo 否)）"

section "远端仓库与工作目录"
if ! runtime_sh "${REPORT_SNIPPET}" "${MTAG}" "${MREV}" "${ITAG}" "${IREV}"; then
  warn "读不到运行态（容器未运行且宿主无权访问卷？）"
fi

if [[ "${RAW}" -eq 1 ]]; then
  section "状态文件（${RUN_DIR}/project_remote_state.json）"
  if [[ -z "${STATE_JSON}" ]]; then
    warn "读不到状态文件"
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "${STATE_JSON}" | jq .
  else
    printf '%s\n' "${STATE_JSON}"
  fi
fi

if [[ "${LOGS}" -gt 0 ]]; then
  section "发布相关日志（最近 ${LOGS} 行）"
  show_logs "${LOGS}"
fi

if [[ -n "${COPY_TO}" ]]; then
  section "导出"
  copy_out "${COPY_TO}"
fi
