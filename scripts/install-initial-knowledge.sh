#!/usr/bin/env bash
# 把**初始知识库内容包**（出厂自带）解开到网关的「启动期知识源」目录。
#
# 谁调用：`gops sys localize` 的 `localize` flow —— 在 `gx.download` 把包拉进 `packages/` 之后。
# 谁消费：网关配置里的 `[knowledge] source_dir`（见 `sys/configs/gateway/wist-gateway.toml.tpl`）。
#         **两处的路径口径必须一致**：下面 `KNOWLEDGE_SOURCE_DIR` 的默认值就是那个契约值，
#         改一处必须同时改另一处。
#
# 为什么不是「存在即跳过」（本仓其它 init-*.sh 的约定）：那条规定是为了**证书/密钥绝不重生成**。
# 内容是**可重放**的，而且必须重放 —— 换版本要覆盖，旧文件残留会让这份包"半新半旧"，
# 比整份缺失更难查。所以这里每次都 `rm -rf` 目标目录再解，输出与输入一一对应。
#
# 用法：scripts/install-initial-knowledge.sh
# 环境（由 `gops sys localize` 以合并后的值注入）：
#   KNOWLEDGE_PKG_URL     包地址（与 flow 里 gx.download 用的是同一个值）；**空 = 跳过**
#                         （但会**显式告警**并说清网关将空载，不再静默）
#   GATEWAY_CONFIG_DIR    网关配置目录（默认 ./configs/gateway）
#   KNOWLEDGE_SOURCE_DIR  解到哪儿（相对网关配置目录；默认 knowledge/initial，须与 tpl 一致）
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${STACK_ROOT}"

url="${KNOWLEDGE_PKG_URL:-}"
if [[ -z "${url}" ]]; then
  # 有意跳过，但**不静默**：空载的后果要说清（它看起来像“装好了”，实际什么都不采）。
  echo "[告警] 跳过初始知识库：KNOWLEDGE_PKG_URL 为空。" >&2
  echo "        网关将以**空载**启动：不产「系统类型」建议 / 用途建议，也无法派采集工作。" >&2
  echo "        需要内容就：① 设可达的 KNOWLEDGE_PKG_URL，或 ② 把包手工放进 packages/，" >&2
  echo "        再在「知识库」页录入并激活（录入 ≠ 生效，要点激活）。" >&2
  exit 0
fi

gcd="${GATEWAY_CONFIG_DIR:-./configs/gateway}"
sd="${KNOWLEDGE_SOURCE_DIR:-knowledge/initial}"
# 文件名从 URL 推（去掉查询串/锚点）——与 gx.download 落盘时的取名口径一致。
pkg_name="$(basename "${url}")"
pkg_name="${pkg_name%%[?#]*}"
pkg="packages/${pkg_name}"
dst="${gcd}/${sd}"

if [[ ! -f "${pkg}" ]]; then
  echo "初始知识库包不在 ${pkg} —— gx.download 没能把它拉下来。" >&2
  echo "  多半是 KNOWLEDGE_PKG_URL 在这台机器上不可达（外网 / GitHub 被墙 / 域名解析不到）：" >&2
  echo "    ${url}" >&2
  echo "  处置：把 ${pkg_name} 手工拷进 packages/ 后重跑本步，或把 KNOWLEDGE_PKG_URL 换成可达镜像。" >&2
  exit 1
fi

rm -rf "${dst}"
mkdir -p "${dst}"
# 包内是 `<name>-<ver>/` 一层前缀（见 wist-knowledge/scripts/package.sh），剥掉这一层：
# 网关要的 `source_dir` 是**五份数据直接躺在里面**的目录。
tar -xzf "${pkg}" -C "${dst}" --strip-components=1

# 兜一手：布局变了要**当场**说，而不是等网关启动时去读那条告警。
missing=""
for f in catalog.toml packs.toml templates.toml purpose-rules.toml aspect-policies.toml; do
  [[ -f "${dst}/${f}" ]] || missing="${missing} ${f}"
done
if [[ -n "${missing}" ]]; then
  echo "包内缺文件：${missing}（${pkg} 的布局与预期不符？）" >&2
  exit 1
fi

echo "初始知识库已就位：${dst} ← ${pkg}"
if [[ -f "${dst}/manifest.json" ]]; then
  ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${dst}/manifest.json" | head -n1)"
  echo "  包版本：${ver:-未知}（网关启动日志会打 knowledge source = dir:<该目录>）"
fi
