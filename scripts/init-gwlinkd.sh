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
#   GWLINKD_AGENT_PACKAGE_CONTAINER_DIR  该目录在网关容器里的路径（缺省 /packages，与 compose 挂载一致）
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
  "${GWLINKD_UPGRADE_PROJECT_DIR:-}" <<'PY'
import json, os, sys, tempfile

path = sys.argv[1]
state, identity, self_ep, self_ca, drop_raw, container, upgrader, upgrade_dir = sys.argv[2:10]
# 投放目录给 gwlinkd 用：空 = 不启用（不渲染）；相对路径 → **绝对**（gwlinkd 的 cwd 不定）。
drop = "" if not drop_raw else (drop_raw if os.path.isabs(drop_raw) else os.path.abspath(drop_raw))
value = {
    "state_dir": state,
    "identity_dir": identity,
    "gateway_self_endpoint": self_ep,
    "gateway_self_ca": self_ca,
    "agent_package_drop_dir": drop,
    "agent_package_container_dir": container,
    "upgrader_program": upgrader,
    "upgrade_project_dir": upgrade_dir,
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
