#!/usr/bin/env bash
# 准备 gwlinkd 的**现场态值**（`identity/gwlinkd/.env`）。
#
# 现场态**声明**（`identity/gwlinkd/gwlinkd-pub.toml`）**不在这里** —— 它只写 `${VAR}` 引用、
# 不含现场值，由 `sys/workflows/operators.gxl` 用 **tpl** 机制渲染
# （`sys/configs/gwlinkd/gwlinkd-pub.toml.tpl` → `identity/gwlinkd/gwlinkd-pub.toml`），
# 与其它交付物同一套渲染；重渲动不到现场（值不在这里）。
#
# 本脚本只做一件事：把 `CENTER_ENDPOINT` / `GWLINKD_GATEWAY_ID` / `GWLINKD_TRUST_BUNDLE`
# 按缺（**键不存在或值为空**）写进 `.env`，**非空一律保留**（现场改过 / 页面接入时写过 / 迁移搬来的）。
#
# 为什么值与声明分开（docker-compose 口径）：声明里只出现 `${VAR}`，真值在 `.env` ——
#   声明可随版本覆盖（重渲），`.env` 是现场唯一写者。gwlinkd 加载时用「进程环境 > 同目录 `.env`」
#   插值；变量名必须与声明 tpl 里的 `${VAR}` 一一对应。
#
# 落点为什么在 `identity/`：它随 `sys-prj.yml: contract` 自动获得「不进包 / 不重渲 / 必进备份」。
#
# 用法：
#   scripts/init-gwlinkd-pub.sh [现场态目录]
#     # 默认 identity/gwlinkd
#
# 幂等：内容没变就不碰文件（不改 mtime）⇒ **可以每次 localize 都跑**。
set -euo pipefail

DIR="${1:-identity/gwlinkd}"
ENV_FILE="${DIR}/.env"

command -v python3 >/dev/null 2>&1 || { echo "缺少 python3，无法生成现场态值" >&2; exit 1; }
mkdir -p "${DIR}"

# 值：按缺补齐（键不存在或值为空才写；非空一律保留）。
python3 - "${ENV_FILE}" \
  "${CENTER_ENDPOINT:-}" \
  "${GWLINKD_GATEWAY_ID:-}" \
  "${GWLINKD_TRUST_BUNDLE:-}" <<'PY'
import os, sys, tempfile

target, center, gateway_id, trust = sys.argv[1:5]

HEADER = "\n".join(
    [
        "# wist-gwlinkd 现场态（接口层）**值** —— 与同目录 gwlinkd-pub.toml 里的 ${VAR} 一一对应。",
        "# 由 scripts/init-gwlinkd-pub.sh 按缺写入（键不存在或值为空才写，非空一律保留）；升级 / 重渲不动它。",
    ]
)
DESIRED = [
    ("CENTER_ENDPOINT", center),
    ("GWLINKD_GATEWAY_ID", gateway_id),
    ("GWLINKD_TRUST_BUNDLE", trust),
]


def unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse(text):
    """现有 `KEY=VALUE` → {键: 值}（注释/空行跳过；去可选引号）。"""
    found = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        found[key.strip()] = unquote(value.strip())
    return found


if os.path.exists(target):
    original = open(target, encoding="utf-8").read()
    existing = parse(original)
    lines = original.splitlines()
    changed = False
    for key, value in DESIRED:
        current = existing.get(key)
        if current is None:
            lines.append(f"{key}={value}")
            changed = True
        elif current == "" and value != "":
            for idx, raw in enumerate(lines):
                head, sep, _ = raw.partition("=")
                if sep and head.strip() == key:
                    lines[idx] = f"{key}={value}"
                    break
            changed = True
    text = "\n".join(lines) + "\n"
    if not changed or text == original:
        print(f"  现场态值与当前一致，跳过：{target}")
        sys.exit(0)
    message = f"  已补齐现场态值：{target}"
else:
    text = HEADER + "\n\n" + "\n".join(f"{key}={value}" for key, value in DESIRED) + "\n"
    message = f"  已生成现场态值：{target}"

directory = os.path.dirname(os.path.abspath(target))
os.makedirs(directory, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".gwlinkd-env-", suffix=".env")
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write(text)
os.chmod(tmp, 0o644)
os.replace(tmp, target)
print(message)
PY
