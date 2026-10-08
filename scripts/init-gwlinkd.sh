#!/usr/bin/env bash
# 生成 gwlinkd 配置模板的**渲染值** configs/gwlinkd/gwlinkd.value.json（localize 里 gx.tpl 的输入）。
#
# gwlinkd 是网关**宿主侧**常驻（CR-003）：它的配置由本栈渲染，与网关配置同一套 localize 机制
# （sys/configs/gwlinkd/gwlinkd.toml.tpl → gx.tpl → configs/gwlinkd/gwlinkd.toml）。
# 一次性接入券 `link_token` **不进渲染值**：它由「链接上级」页/gwlinkd 自联时写进 rendered 配置。
#
# 用法：
#   scripts/init-gwlinkd.sh [输出目录]        # 默认 configs/gwlinkd
#
# 读合并后的系统变量（gops 以环境变量注入本子进程；见 sys/setting/vars.yml）：
#   CENTER_ENDPOINT        上级控制中心地址（空 = 还没接，等页面/自联时写）
#   GWLINKD_GATEWAY_ID     本网关在中心侧的标识
#   GWLINKD_TRUST_BUNDLE   中心 CA-S 信任锚路径（自签中心必需）
#   GWLINKD_STATE_DIR      gwlinkd 状态/身份目录
#   GATEWAY_SELF_ENDPOINT  本机网关环回面（页面路用；空 = 不配）
#   GATEWAY_SELF_CA        环回面信任锚（空 = 系统根）
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
  "${CENTER_ENDPOINT:-}" \
  "${GWLINKD_GATEWAY_ID:-gw-local}" \
  "${GWLINKD_TRUST_BUNDLE:-./configs/gwlinkd/control-center.pem}" \
  "${GWLINKD_STATE_DIR:-./configs/gwlinkd/state}" \
  "${GATEWAY_SELF_ENDPOINT:-}" \
  "${GATEWAY_SELF_CA:-}" <<'PY'
import json, os, sys, tempfile

path = sys.argv[1]
center, gwid, trust, state, self_ep, self_ca = sys.argv[2:8]
value = {
    "center_endpoint": center,
    "gateway_id": gwid,
    "trust_bundle": trust,
    "state_dir": state,
    "gateway_self_endpoint": self_ep,
    "gateway_self_ca": self_ca,
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
