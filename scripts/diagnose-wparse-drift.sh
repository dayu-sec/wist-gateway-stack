#!/bin/sh
# `gops run diagnose` 的系统流程：**工作目录 vs 远端克隆**的逐文件比对。
#
# 这是「本系统专属的期望」：wparse 在 `/data` 工作，配置来自
# `/data/.run/project_remote/{remote-models,remote-infra}` 的克隆；两者不一致 =
# 发布/同步只落了一半（典型现场：clone 里多了 sink，/data 里没有，规则静默不生效）。
#
# 契约（`galaxy-ops/docs/design/run-diagnose.md`）：
#   - 写  `$GOPS_DIAGNOSE_RESULT`（Flow Result v1，`checks[]`）
#   - 读  `$GOPS_DIAGNOSE_CONTEXT`（本脚本用不到：容器由 compose 自己找）
#
# **只读**：不写 `/data`、不 chmod、不重启；容器里只用 `find` + hash。
#
# 环境变量：
#   WPARSE_SERVICE           compose 服务名（缺省 wparse）
#   WPARSE_DRIFT_MAX_DETAIL  detail 里最多列几条差异（缺省 10）

set -eu

RESULT="${GOPS_DIAGNOSE_RESULT:?缺少 GOPS_DIAGNOSE_RESULT（应由 gops run diagnose 注入）}"
SERVICE="${WPARSE_SERVICE:-wparse}"
MAX_DETAIL="${WPARSE_DRIFT_MAX_DETAIL:-10}"

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/ /g' | tr '\n' ' '
}

checks=""
add_check() { # $1=code $2=status $3=title $4=detail $5=hint [$6=evidence JSON]
  ev=""
  if [ -n "${6:-}" ]; then
    ev=",\"evidence\":$6"
  fi
  item="{\"code\":\"$1\",\"status\":\"$2\",\"title\":\"$(json_escape "$3")\",\"detail\":\"$(json_escape "$4")\",\"hint\":\"$(json_escape "$5")\"$ev}"
  if [ -z "$checks" ]; then
    checks="$item"
  else
    checks="$checks,$item"
  fi
}

write_result() {
  printf '{"schema_version":"1","source":"diagnose","checks":[%s]}\n' "$checks" >"$RESULT"
}

# compose 发现：内收布局（sys/）与旧布局都认；显式 -f 时 compose 不再自动合 override，
# 所以同目录的 override 也要显式带上（与 gops 的 compose_invocation 同口径）。
compose_file=""
override_file=""
for candidate in sys/docker-compose.yml sys/docker-compose.yaml sys/compose.yml sys/compose.yaml \
  docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
  if [ -f "$candidate" ]; then
    compose_file="$candidate"
    break
  fi
done
if [ -n "$compose_file" ]; then
  dir=$(dirname "$compose_file")
  for candidate in "$dir/docker-compose.override.yml" "$dir/docker-compose.override.yaml"; do
    if [ -f "$candidate" ]; then
      override_file="$candidate"
      break
    fi
  done
fi

compose_ps_container() {
  if [ -n "$compose_file" ] && [ -n "$override_file" ]; then
    docker compose -f "$compose_file" -f "$override_file" --project-directory . ps -q "$SERVICE"
  elif [ -n "$compose_file" ]; then
    docker compose -f "$compose_file" --project-directory . ps -q "$SERVICE"
  else
    docker compose ps -q "$SERVICE"
  fi
}

# 比对豁免：哪些文件不参与“clone vs work”全等比对。
# 两个来源（后者追加到前者）：
#   - 环境变量 WPARSE_DRIFT_IGNORE（空格分隔的 glob，相对 tree 根，如 "./conf/wparse.toml"）
#   - sys/diagnose/drift-ignore.txt（一行一个 glob，`#` 注释）
# 典型豁免：由模板渲染 / 现场手工调整的配置文件（它们的“不同”是设计使然）。
ignore_patterns="${WPARSE_DRIFT_IGNORE:-}"
if [ -f sys/diagnose/drift-ignore.txt ]; then
  from_file=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' sys/diagnose/drift-ignore.txt | tr '\n' ' ')
  ignore_patterns="$ignore_patterns $from_file"
fi

# 跑因历史：上次的漂移清单（相对系统根；放在运行目录下，不污染交付物）。
state_dir="${WPARSE_DIAGNOSE_STATE_DIR:-data-plane-run/diagnose}"
prev_drift="$state_dir/work-drift.prev"
mkdir -p "$state_dir" 2>/dev/null || true

container=""
if command -v docker >/dev/null 2>&1; then
  container=$(compose_ps_container 2>/dev/null | head -n 1 || true)
fi

if [ -z "$container" ] || [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false)" != "true" ]; then
  add_check "wparse.work_drift" "warn" \
    "未比对：wparse 容器未运行" \
    "docker compose ps 找不到运行中的服务 ${SERVICE}（compose_file=${compose_file:-<auto>}）" \
    "先运行 gops run status 确认容器状态；容器起来后再跑一次"
  write_result
  exit 0
fi

# 容器内采集：每个 tree 输出 COUNT 或若干 DRIFT，最后一组 VERSION。
# 脚本通过 **stdin** 交给容器（sh -s）：不用“命令替换套 heredoc”（macOS 的 sh 解析不稳），
# 也避免在宿主侧做任何字符串拼接。
snippet_file=$(mktemp)
cat >"$snippet_file" <<'EOS'
set -u
R=/data/.run/project_remote
W=/data
STATE_FILE=/data/.run/project_remote_state.json
: "${WPARSE_DRIFT_IGNORE:=}"
ignored() { # $1=相对路径（./ 开头），命中所配 glob 则不参与比对
  for pat in $WPARSE_DRIFT_IGNORE; do
    case "$1" in $pat) return 0 ;; esac
  done
  return 1
}
if command -v sha256sum >/dev/null 2>&1; then HASH="sha256sum"
elif command -v shasum >/dev/null 2>&1; then HASH="shasum -a 256"
else HASH="openssl dgst -sha256 -r"; fi
hash_file() { $HASH "$1" | cut -d" " -f1; }
list_tree() {
  ( cd "$1" 2>/dev/null && find . -type f 2>/dev/null | LC_ALL=C sort |
      while IFS= read -r f; do
        if ignored "$f"; then continue; fi
        printf "%s %s\n" "$(hash_file "$f")" "$f"
      done )
}
compare() { # $1=tree  $2=repo dir  $3=subdir
  tree="$1"; src="$2/$3"; dst="$W/$3"
  if [ ! -d "$src" ]; then printf "MISSING %s\n" "$tree"; return; fi
  a=$(mktemp); b=$(mktemp)
  list_tree "$src" > "$a"; list_tree "$dst" > "$b"
  awk -v tree="$tree" '
    FNR==NR { h[$2]=$1; next }
    { h2[$2]=$1 }
    END {
      for (p in h) {
        if (p in h2) { if (h[p] != h2[p]) print "DRIFT " tree " changed " p }
        else print "DRIFT " tree " only-clone " p
      }
      for (p in h2) if (!(p in h)) print "DRIFT " tree " only-work " p
      print "COUNT " tree " " length(h)
    }' "$a" "$b"
  rm -f "$a" "$b"
}
compare models "$R/remote-models" models
compare conf "$R/remote-infra" conf
compare topology "$R/remote-infra" topology
compare connectors "$R/remote-infra" connectors

head_of() { # $1=repo dir：不依赖容器里有 git
  h=$(tr -d '\n' < "$1/.git/HEAD" 2>/dev/null || true)
  case "$h" in
    "ref: "*)
      ref=$(printf '%s' "${h#ref: }" | tr -d '\n')
      cat "$1/.git/$ref" 2>/dev/null | tr -d '\n' ||
        sed -n "s/^\([0-9a-f]\{40\}\) $ref$/\1/p" "$1/.git/packed-refs" 2>/dev/null
      ;;
    *) printf '%s' "$h" ;;
  esac
}
state_rev() { # $1=models|infra（state 是多行 JSON：先去换行再匹配）
  tr -d '\n' < "$STATE_FILE" 2>/dev/null |
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*{[^}]*\"revision\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" |
    head -n 1
}
for group in models infra; do
  case "$group" in
    models) repo="$R/remote-models" ;;
    infra) repo="$R/remote-infra" ;;
  esac
  s=$(state_rev "$group")
  h=$(head_of "$repo")
  printf "VERSION %s %s %s\n" "$group" "${s:--}" "${h:--}"
done
EOS

report=""
if ! report=$(docker exec -e "WPARSE_DRIFT_IGNORE=$ignore_patterns" -i "$container" sh -s <"$snippet_file" 2>&1); then
  rm -f "$snippet_file"
  add_check "wparse.work_drift" "warn" \
    "未比对：容器内采集失败" \
    "$report" \
    "手工执行 docker exec 进容器看 /data/.run/project_remote 是否存在"
  write_result
  exit 0
fi
rm -f "$snippet_file"

# 采集完整性：4 个 tree 每个都必须给一行 COUNT 或 MISSING；少一行说明容器内脚本中途挂了
# （典型：变量未定义 / sed 不支持）——这时**不能**当成“一致”。
trees_seen=$(printf '%s\n' "$report" | grep -Ec '^(COUNT|MISSING) ' || true)
if [ "${trees_seen:-0}" -lt 4 ]; then
  add_check "wparse.work_drift" "warn" \
    "未比对：容器内采集不完整" \
    "$report" \
    "手工进容器确认 /data/.run/project_remote 与 /data 的目录结构"
  write_result
  exit 0
fi

drift=$(printf '%s\n' "$report" | sed -n 's/^DRIFT //p')
missing=$(printf '%s\n' "$report" | sed -n 's/^MISSING //p')
counts=$(printf '%s\n' "$report" | sed -n 's/^COUNT //p' | awk '{ n += $2 } END { print n + 0 }')

# 漂移清单落盘并跟上次比：区分“本次新增 / 既有 / 已修复”（P0-4）。
cur_drift=$(mktemp)
printf '%s\n' "$drift" | sed '/^$/d' | LC_ALL=C sort >"$cur_drift"
drift_n=$(wc -l <"$cur_drift" | tr -d ' ')
new_n=0
fixed_n=0
new_preview=""
if [ -f "$prev_drift" ]; then
  new_lines=$(mktemp)
  fixed_lines=$(mktemp)
  comm -13 "$prev_drift" "$cur_drift" >"$new_lines" 2>/dev/null || true
  comm -23 "$prev_drift" "$cur_drift" >"$fixed_lines" 2>/dev/null || true
  new_n=$(wc -l <"$new_lines" | tr -d ' ')
  fixed_n=$(wc -l <"$fixed_lines" | tr -d ' ')
  new_preview=$(head -n 3 "$new_lines" | tr '\n' ';' | sed 's/;$//')
  rm -f "$new_lines" "$fixed_lines"
fi
# 原子落盘：下一次就以本次为基线
mv -f "$cur_drift" "$prev_drift" 2>/dev/null || true

if [ "$drift_n" = "0" ] && [ -z "$missing" ]; then
  add_check "wparse.work_drift" "ok" \
    "工作目录与远端克隆一致（$counts 个文件）" \
    "models / conf / topology / connectors 逐文件 sha256 相同${ignore_patterns:+（已豁免：${ignore_patterns}）}" \
    ""
else
  if [ -n "$new_preview" ]; then
    detail="新增 ${new_n} 处：$new_preview"
    [ "$fixed_n" -gt 0 ] && detail="${detail}；已修复 ${fixed_n} 处"
    detail="${detail}；既有 $((drift_n - new_n)) 处"
  else
    detail=$(printf '%s\n' "$drift" | head -n "$MAX_DETAIL" | tr '\n' ';')
    [ "$drift_n" -gt "$MAX_DETAIL" ] && detail="${detail}……（共 ${drift_n} 处，仅列前 ${MAX_DETAIL}）"
  fi
  if [ -n "$missing" ]; then
    detail="克隆缺失：$(printf '%s' "$missing" | tr '\n' ',')；$detail"
  fi
  title="工作目录与远端克隆不一致（$drift_n 处"
  [ "$new_n" -gt 0 ] && title="${title}，新增 ${new_n}"
  title="${title}）"
  add_check "wparse.work_drift" "fail" \
    "$title" \
    "$detail" \
    "先确认发布/同步是否只更新了 clone；逐文件明细用 scripts/show-wparse-state.sh" \
    "{\"total\":$drift_n,\"new\":$new_n,\"fixed\":$fixed_n}"
fi

# 已应用版本 vs 克隆 HEAD（state 说一套、实际跑另一套时，这里能直接看出来）。
versions=$(printf '%s\n' "$report" | sed -n 's/^VERSION //p')
while IFS=' ' read -r group state head; do
  [ -n "${group:-}" ] || continue
  if [ "${state:-}" = "-" ] || [ "${head:-}" = "-" ]; then
    add_check "wparse.applied_version.$group" "warn" \
      "$group 版本未确认" \
      "state=${state:-<空>} head=${head:-<空>}（state 文件缺失或克隆未初始化）" \
      "确认 /data/.run/project_remote_state.json 与克隆是否存在"
  elif [ "$state" = "$head" ]; then
    add_check "wparse.applied_version.$group" "ok" \
      "$group 已应用版本与克隆一致" \
      "revision=$head" \
      ""
  else
    add_check "wparse.applied_version.$group" "warn" \
      "$group 已应用版本与克隆不一致" \
      "state=$state head=$head" \
      "上一次同步没走到最后一步；重新触发一次发布/同步"
  fi
done <<EOF2
$versions
EOF2

write_result
