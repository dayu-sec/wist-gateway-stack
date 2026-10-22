#!/usr/bin/env bash
# 生成 gwlinkd **主配置**模板的渲染值 configs/gwlinkd/gwlinkd.value.json（localize 里 gx.tpl 的输入）。
#
# gwlinkd 是网关**宿主侧**常驻（CR-003）：主配置由本栈渲染，与网关配置同一套 localize 机制
# （sys/configs/gwlinkd/gwlinkd.toml.tpl → gx.tpl → configs/gwlinkd/gwlinkd.toml）。
#
# **主配置只放交付物类项**（运行态目录 / 环回自述面 / 投放目录 / 升级参数）：升级 / 重渲该被覆盖。
# 现场选择（上级中心地址 / 网关标识 / 中心信任锚 / 一次性接入券）**不在**这里 ——
# 它们是现场态（**声明 + 值分开**）：声明在 `identity/gwlinkd/gwlinkd-pub.toml`（由 tpl 渲染），
# 值在 `identity/gwlinkd/.env`（scripts/init-gwlinkd-pub.sh 按缺补齐；页面接入时写入）。
# **本脚本不碰现场态**。
#
# 用法：
#   scripts/init-gwlinkd.sh [输出目录]        # 默认 configs/gwlinkd
#
# 读合并后的系统变量（gops 以环境变量注入本子进程；见 sys/setting/vars.yml）：
#   GWLINKD_STATE_DIR              运行态目录（锁 / 升级簿记 / 临时注册券；可删可重建）
#   GWLINKD_IDENTITY_DIR           身份目录（客户端证书 + 私钥、中心信任锚）—— 进 contract；空 = 不渲染（回落 state_dir）
#   GATEWAY_SELF_ENDPOINT          本机网关环回面（页面路用；空 = 不配）
#   GATEWAY_SELF_CA                环回面信任锚（空 = 系统根）
#   PACKAGE_DIR                    发布 ② 投放目录（宿主侧；渲染为**绝对路径**给 gwlinkd；空 = 不渲染）
#                                  gwlinkd 实际用的是它的 `agents/` 子目录（见下）
#   GWLINKD_AGENT_PACKAGE_CONTAINER_DIR  该目录在网关容器里的路径（缺省 /packages，与 compose 挂载一致）
#                                  渲染给 gwlinkd 时自动补 `/agents`（即 `/packages/agents`）
#   GWLINKD_UPGRADER_PROGRAM       升级执行器程序（空 = 不渲染，用 gwlinkd 缺省 gops）
#   GWLINKD_UPGRADE_PROJECT_DIR    gops 工程根（含 ops-prj.yml；空 = 不渲染；**绝对路径**）
#
# 注意：**现场选择**（GWLINKD_CENTER_ENDPOINT / GWLINKD_GATEWAY_ID / GWLINKD_TRUST_BUNDLE）**不经过本脚本**
# —— 它们由 `scripts/init-gwlinkd-pub.sh` 写进现场态**值文件** `identity/gwlinkd/.env`
# （**只写该值文件，不动声明 toml**）。
#
# 幂等：内容与当前一致就跳过（不碰 mtime）。
set -euo pipefail

OUT_DIR="${1:-configs/gwlinkd}"
VALUE_JSON="${OUT_DIR}/gwlinkd.value.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

note() { echo "  $*"; }

command -v python3 >/dev/null 2>&1 || { echo "缺少 python3，无法生成 ${VALUE_JSON}" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# 用 python3 组装 JSON（值可能含路径；不走 shell printf 转义 —— 与 init-web-conf.sh 同一理由）。
python3 - "$VALUE_JSON" \
  "${GWLINKD_STATE_DIR:-./configs/gwlinkd/state}" \
  "${GWLINKD_IDENTITY_DIR:-}" \
  "${GATEWAY_SELF_ENDPOINT:-}" \
  "${GATEWAY_SELF_CA:-}" \
  "${PACKAGE_DIR:-./packages}" \
  "${GWLINKD_AGENT_PACKAGE_CONTAINER_DIR:-/packages}" \
  "${GWLINKD_UPGRADER_PROGRAM:-}" \
  "${GWLINKD_UPGRADE_PROJECT_DIR:-}" \
  "${STACK_ROOT}" \
  "${WPARSE_ADMIN_PORT:-19090}" <<'PY'
import json, os, sys, tempfile

path = sys.argv[1]
state, identity, self_ep, self_ca, drop_raw, container, upgrader, upgrade_dir, stack_root, admin_port = sys.argv[2:12]
# 投放目录给 gwlinkd 用：空 = 不启用（不渲染）；相对路径 → **绝对**（gwlinkd 的 cwd 不定）。
# ② 的交付区独占一个子目录：`packages/` 同时放知识库包与人工投放的安装包，而 gwlinkd 交付后
# 按 mtime 只保留最新 N 份（`prune_drop_dir` **不区分类型**）—— 混放会把知识库包连带清掉。
# 容器里就是 `${container}/agents`（同一个 compose 挂载，不用额外加 volume）。
AGENT_PACKAGE_SUBDIR = "agents"
if not drop_raw:
    drop = ""
else:
    base = drop_raw if os.path.isabs(drop_raw) else os.path.abspath(drop_raw)
    drop = os.path.join(base, AGENT_PACKAGE_SUBDIR)
container = f"{container.rstrip('/')}/{AGENT_PACKAGE_SUBDIR}" if container else ""
value = {
    "state_dir": state,
    "identity_dir": identity,
    "gateway_self_endpoint": self_ep,
    "gateway_self_ca": self_ca,
    "agent_package_drop_dir": drop,
    "agent_package_container_dir": container,
    "upgrader_program": upgrader,
    "upgrade_project_dir": upgrade_dir,
    # WarpParse 管理面中继（WarpStation 发布链路）。gwlinkd 实现 [wparse_relay] 后生效。
    "wparse_relay_enabled": "true",
    "wparse_relay_upstream": f"https://127.0.0.1:{admin_port}",
    "wparse_relay_ca": os.path.join(stack_root, "identity/gateway/public/gateway-ca.crt.pem"),
    "wparse_relay_token": os.path.join(stack_root, "data-plane-run/.run/admin_api.token.host"),
}
text = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
if os.path.exists(path):
    with open(path, encoding="utf-8") as handle:
        if handle.read() == text:
            print(f"  渲染值与当前一致，跳过：{path}")
            sys.exit(0)
directory = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".gwlinkd-value-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write(text)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
print(f"  已写渲染值：{path}")
PY
