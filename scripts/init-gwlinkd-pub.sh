#!/usr/bin/env bash
# 准备 gwlinkd 的**现场态值**（`identity/gwlinkd/.env`）。
#
# 现场态**声明**（`identity/gwlinkd/gwlinkd-pub.toml`）**不在这里** —— 它只写 `${VAR}` 引用、
# 不含现场值，由 `sys/workflows/operators.gxl` 用 **tpl** 机制渲染
# （`sys/configs/gwlinkd/gwlinkd-pub.toml.tpl` → `identity/gwlinkd/gwlinkd-pub.toml`），
# 与其它交付物同一套渲染；重渲动不到现场（值不在这里）。
#
# 本脚本做两件事：
#   1) 把 `GWLINKD_CENTER_ENDPOINT` / `GWLINKD_GATEWAY_ID` / `GWLINKD_TRUST_BUNDLE` 按缺
#      （**键不存在或值为空**）写进 `.env`，**非空一律保留**（现场改过 / 页面接入时写过 / 迁移搬来的）。
#   2) **清掉死键**：`.env` 里存在、但同目录 `gwlinkd-pub.toml` **没有引用**的键。
#
# 为什么值与声明分开（docker-compose 口径）：声明里只出现 `${VAR}`，真值在 `.env` ——
#   声明可随版本覆盖（重渲），`.env` 是现场唯一写者。gwlinkd 加载时用「进程环境 > 同目录 `.env`」
#   插值；变量名必须与声明 tpl 里的 `${VAR}` 一一对应。
#
# 落点为什么在 `identity/`：它随 `sys-prj.yml: contract` 自动获得「不进包 / 不重渲 / 必进备份」。
#
# 为什么要清死键：变量名一旦改过（如早先的 `CENTER_ENDPOINT` / `GATEWAY_ID` / `TRUST_BUNDLE`），
# 旧键会残在 `.env` 里。它**不生效**，但看着像“配了”（最坑的是 `TRUST_BUNDLE=` 空着 ——
# 看着像信任锚没配，实际生效的是 `GWLINKD_TRUST_BUNDLE`）。判据不是硬编码键名，
# 而是**声明文件里引用的 `${VAR}`**：一个键只要没被声明引用，它就没有任何读取方。
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

# 值：按缺补齐（键不存在或值为空才写；非空一律保留），并清掉声明未引用的死键。
python3 - "${ENV_FILE}" "${DIR}/gwlinkd-pub.toml" \
  "${GWLINKD_CENTER_ENDPOINT:-}" \
  "${GWLINKD_GATEWAY_ID:-}" \
  "${GWLINKD_TRUST_BUNDLE:-}" <<'PY'
import os, re, sys, tempfile

target, declaration, center, gateway_id, trust = sys.argv[1:6]

HEADER = "\n".join(
    [
        "# wist-gwlinkd 现场态（接口层）**值** —— 与同目录 gwlinkd-pub.toml 里的 ${VAR} 一一对应。",
        "# 由 scripts/init-gwlinkd-pub.sh 按缺写入（键不存在或值为空才写，非空一律保留）；升级 / 重渲不动它。",
    ]
)
DESIRED = [
    ("GWLINKD_CENTER_ENDPOINT", center),
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


DECLARED = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)")


def declared_names(path):
    """声明文件里被 `${VAR}` 引用的变量名集合。

    读不到 → `None`（**不**清死键）：拿一个空集合去删会把整个 `.env` 清空。
    """
    try:
        return set(DECLARED.findall(open(path, encoding="utf-8").read()))
    except OSError:
        return None


def prune(lines, declared):
    """去掉未被声明引用的赋值行（注释 / 空行原样保留）。返回 (保留的行, 被删的键)。"""
    kept, removed = [], []
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#") or "=" not in raw:
            kept.append(raw)
            continue
        key = raw.partition("=")[0].strip()
        if key not in declared:
            removed.append(key)
            continue
        kept.append(raw)
    return kept, removed


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
    # 清死键：声明没引用的键没有任何读取方（改名后的残留 / 旧版骶架留下的）。
    declared = declared_names(declaration)
    removed = []
    if declared is not None:
        lines, removed = prune(lines, declared)
    text = "\n".join(lines) + "\n"
    if (not changed and not removed) or text == original:
        print(f"  现场态值与当前一致，跳过：{target}")
        sys.exit(0)
    note = f"（清掉未声明的死键：{', '.join(sorted(set(removed)))}）" if removed else ""
    message = f"  已补齐现场态值：{target}{note}"
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
