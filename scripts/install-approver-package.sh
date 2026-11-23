#!/usr/bin/env bash
# 投放 `wist-approve` 制品，供网关的 `/api/v1/approver/...` 分发面使用。
#
# 为什么需要这一步：网关不构建任何东西（镜像只来自 CI），它只负责**分发**已经存在的
# 制品。制品来自 `wist-gateway` 仓的 release（`wist-approve-<tag>-<triple>.tar.gz`），
# 本脚本把它们放到网关读得到的位置：
#
#   <栈根>/configs/gateway/state/approver-package/<triple>/wist-approve
#
# 用法：
#   scripts/install-approver-package.sh                 # 按 GATEWAY_TAG 从 GitHub Release 拉
#   scripts/install-approver-package.sh --tag v0.57.0-alpha
#   scripts/install-approver-package.sh --from ./downloads   # 离线：用本地已下好的 tar.gz
#   scripts/install-approver-package.sh --check --tag v0.57.0-alpha   # 只检查，不写
#
# 制品源基址（含仓库 + 渠道）默认是 GitHub Release，可换成 COS 镜像（同 `vars.yml` 里
# knowledge 那个镜像的桶，前缀换成 wist-gateway）：
#   APPROVER_ARTIFACT_BASE=https://<COS 桶域>/wist-gateway scripts/install-approver-package.sh --tag v0.57.0-alpha
#
# 落到哪儿可用 `APPROVER_PACKAGE_DIR=` 覆盖（测试用）；现场保持默认。
#
# 幂等：同一个 tag 重复跑，内容一致就跳过（不会每次重写）。
# 不接进 localize（`sys/workflows/operators.gxl`）：隔离站点没有外网，挂上去会让
# `gops sys localize` / 升级的 regenerate 阶段直接失败；而且制品文件名固定，
# `gx.download` 的 reuse_cache 不判版本，升 tag 也不会更新。部署后手工跑一次。
# 是否漏投由 `--check` 判（含「制品是哪个 tag 投的」——记在 VERSION 文件里）。
set -euo pipefail

trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR

STACK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# `APPROVER_PACKAGE_DIR` 覆盖是为了测试能在临时目录里跑（同 `PACKAGE_DIR` 之于
# `import-package.sh`）；现场不用传，默认就是网关挂进去的那个 state 子目录。
TARGET_DIR="${APPROVER_PACKAGE_DIR:-${STACK_ROOT}/configs/gateway/state/approver-package}"
# 三个 triple 必须与网关分发白名单一致（`src/api/install_package.rs` 的 PLATFORM_*
# 常量，审批分发面复用它），也与 CI 的 build-approver-cli 矩阵一致（Linux 静态 musl）。
# 投到白名单外的名字，网关不会去读那个目录 —— 下载端点会一直 503。
PLATFORMS=(aarch64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl)

TAG="${GATEWAY_TAG:-}"
FROM_DIR=""
CHECK_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --from) FROM_DIR="${2:-}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    # 头部注释块就是帮助文本：按注释块动态取，不硬编码行号（加一行注释就会漂）。
    -h|--help) awk 'NR>1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

# 制品源基址：**已包含「仓库 + 发布渠道」前缀**，下载地址 = `<基址>/<tag>/<文件名>`。
# 与栈里的 `ARTIFACT_HOME` + `KNOWLEDGE_PATH` 同一形态，但**不能直接复用那个变量**：
# `ARTIFACT_HOME` 在栈里指的是 wist-knowledge 仓（默认还指向 COS 镜像），仓库名不同，
# 拿来拼 wist-gateway 的地址会得到一个不存在的路径。
#
#   直连 GitHub（缺省）：https://github.com/dayu-sec/wist-gateway/releases/download
#   国内 COS 镜像：       https://<COS 桶域>/wist-gateway
#                        （`upload-cos` 把 Release 附件原样推到 `<prefix=仓名>/<tag>/<文件名>`，
#                          与 knowledge 的对象键排布一致 —— 同桶时只换前缀，路径段两边都成立）
#
# 现场覆盖：APPROVER_ARTIFACT_BASE=... scripts/install-approver-package.sh --tag <tag>
# （走不到外网就 `--from <离线目录>`；本脚本**不**读 .env / vars，故意不靠隐式环境。）
APPROVER_ARTIFACT_BASE="${APPROVER_ARTIFACT_BASE:-https://github.com/dayu-sec/wist-gateway/releases/download}"
APPROVER_ARTIFACT_BASE="${APPROVER_ARTIFACT_BASE%/}"

note() { printf '  %s\n' "$*"; }

# 投放时的 tag 记在 VERSION 里：制品的文件名是固定的（`<triple>/wist-approve`），
# 不记版本的话，升了 `GATEWAY_TAG` 还没重新投放这件事**没有任何地方看得出来** ——
# 审批人下载到的还是旧 CLI，而 `--check` 一片绿。
VERSION_FILE="${TARGET_DIR}/VERSION"

# 现状巡检只在 `--check` 下打印：投放模式下先报一屏「缺少」，看着像失败。
if [ "$CHECK_ONLY" -eq 1 ]; then
  missing=0
  for platform in "${PLATFORMS[@]}"; do
    if [ -f "${TARGET_DIR}/${platform}/wist-approve" ]; then
      note "已就位 ${platform}"
    else
      note "缺少   ${platform}"
      missing=$((missing + 1))
    fi
  done
  if [ -f "$VERSION_FILE" ]; then
    installed="$(cat "$VERSION_FILE")"
    note "投放版本 ${installed}"
    # 只在**能知道期望版本**时才比较（手动跑常常不传 tag）。不一致不算失败：
    # 旧版制品仍然能分发，只是审批人拿到的是旧 CLI。
    if [ -n "$TAG" ] && [ "$installed" != "$TAG" ]; then
      echo "提醒：制品是 ${installed}，当前 tag 是 ${TAG} —— 需要重新投放（--tag ${TAG}）" >&2
    fi
  else
    note "投放版本 未知（没有 VERSION 文件）"
  fi
  if [ "$missing" -gt 0 ]; then
    echo "共 ${missing} 个平台缺制品；网关的 /api/v1/approver/... 对这些平台会回 503。" >&2
    exit 1
  fi
  echo "三个平台的制品都已就位。"
  exit 0
fi

if [ -z "$FROM_DIR" ] && [ -z "$TAG" ]; then
  echo "没有 tag：请给 --tag，或在 .env 里设置 GATEWAY_TAG，或用 --from <目录>" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

placed=0
uptodate=0
failed=0

for platform in "${PLATFORMS[@]}"; do
  dest_dir="${TARGET_DIR}/${platform}"
  dest="${dest_dir}/wist-approve"

  if [ -n "$FROM_DIR" ]; then
    src=""
    # 优先用带 tag 的规范名，否则退回通配名（离线目录里文件名常常只剩 triple）。
    # 用 glob 循环而不是 `find | head -1`：后者在 pipefail 下会被 head 提前关闭管道
    # 冒成 SIGPIPE，把「找到了」误判成失败。
    for candidate in "${FROM_DIR}/wist-approve-${TAG}-${platform}.tar.gz" \
                     "${FROM_DIR}/wist-approve-"*"-${platform}.tar.gz"; do
      if [ -f "$candidate" ]; then src="$candidate"; break; fi
    done
    if [ -z "$src" ]; then
      echo "本地找不到 ${platform} 的制品（${FROM_DIR}）—— 跳过" >&2
      failed=$((failed + 1))
      continue
    fi
  else
    src="${WORK_DIR}/wist-approve-${TAG}-${platform}.tar.gz"
    url="${APPROVER_ARTIFACT_BASE}/${TAG}/wist-approve-${TAG}-${platform}.tar.gz"
    note "下载 ${platform} ← ${url}"
    if ! curl -fsSL "$url" -o "$src"; then
      echo "下载失败：${url}（可用 --from 走离线）" >&2
      failed=$((failed + 1))
      continue
    fi
  fi

  mkdir -p "$dest_dir"
  # 先解到临时目录，再按内容决定要不要覆盖 —— 幂等是真的（同 tag 重跑不动已就位的文件），
  # 也不是靠注释声称的。
  staged="${WORK_DIR}/staged-${platform}"
  rm -rf "$staged"; mkdir -p "$staged"
  tar -xzf "$src" -C "$staged" wist-approve 2>/dev/null || {
    # tarball 里可能带前缀目录；兜底整包解开再找。
    tar -xzf "$src" -C "$staged"
  }
  found="$(find "$staged" -name wist-approve -type f -print -quit)"
  if [ -z "$found" ]; then
    echo "包内没有 wist-approve：${src}" >&2
    failed=$((failed + 1))
    continue
  fi
  if [ ! -s "$found" ]; then
    echo "包内的 wist-approve 是空文件：${src}" >&2
    failed=$((failed + 1))
    continue
  fi
  if [ -f "$dest" ] && cmp -s "$found" "$dest"; then
    chmod 0644 "$dest"
    note "已是最新 ${platform}（内容相同，未重写）"
    uptodate=$((uptodate + 1))
    continue
  fi
  cp "$found" "$dest.tmp"
  chmod 0644 "$dest.tmp"
  mv -f "$dest.tmp" "$dest"
  placed=$((placed + 1))
  note "已投放 ${platform} → ${dest}"
done

echo
# 部分失败时不写 VERSION：盘上会是「一半新一半旧」的混合态，而 VERSION 只有一个值 ——
# 写下去等于把这个事实抹掉，下一次 `--check` 会说「投放版本 vX」而其实有一个平台还是旧的。
if [ "$failed" -gt 0 ]; then
  echo "共 ${failed} 个平台未能投放（新投 ${placed}，已是最新 ${uptodate}）。" >&2
  echo "盘上可能已是混合版本，本次**没有**更新 VERSION 记录。修好缺的那几个平台再跑一次。" >&2
  exit 1
fi

if [ -n "$TAG" ]; then
  mkdir -p "$TARGET_DIR"
  printf '%s\n' "$TAG" > "$VERSION_FILE"
  echo "已记录投放版本：${TAG}"
fi
echo "提示：网关容器挂的是 configs/gateway/state，**不需要重启**；重新下载即可拿到。"
echo "核对：scripts/install-approver-package.sh --check"
echo "客户侧安装：curl -fsSLk '<网关>/api/v1/approver/install/<triple>/install.sh' | sh"
