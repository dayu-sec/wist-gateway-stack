#!/usr/bin/env bash
# 准备 gwlinkd 的**现场态值**（`identity/gwlinkd/.env`）。
#
# 现场态**声明**（`identity/gwlinkd/gwlinkd-pub.toml`）**不在这里** —— 它只写 `${VAR}` 引用、
# 不含现场值，由 `sys/workflows/operators.gxl` 用 **tpl** 机制渲染
# （`sys/configs/gwlinkd/gwlinkd-pub.toml.tpl` → `identity/gwlinkd/gwlinkd-pub.toml`），
# 与其它交付物同一套渲染；重渲动不到现场（值不在这里）。
#
# 本脚本做四件事：
#   1) 把 `GWLINKD_CENTER_ENDPOINT` / `GWLINKD_GATEWAY_ID` / `GWLINKD_TRUST_BUNDLE` 按缺
#      （**键不存在或值为空**）写进 `.env`，**非空一律保留**（现场改过 / 页面接入时写过 / 迁移搬来的）。
#      **唯一例外是「路径型键的搬家自愈」**：非空值指向的文件已不存在、而期望位置
#      （`<现场态目录>/control-center.pem`）确实有 —— 那就改写成期望位置。
#      只在这一种形状下改写：指向真在的自定义路径一律保留，期望位置也没有就只告警（不猜）。
#   2) **清掉死键**：`.env` 里存在、但同目录 `gwlinkd-pub.toml` **没有引用**的键。
#   3) **清掉信任锚位置的 docker 空目录**：源文件缺失时 docker 会把 bind 建成同名目录，
#      文件永远写不进去，挂进 wparse 还会让它起不来（详见下面 PATH_KEYS 处的注释）。
#
# 为什么需要自愈：`.env` 是**现场值**（永不重写），而站点目录会被 `mv` / 拷贝到新位置。
#   搬家后 `.env` 里的**绝对路径**（如信任锚）就指向旧位置 —— 指针还“有值”，于是
#   gwlinkd 找不到 PEM、回落系统根，自签中心报 `invalid peer certificate: UnknownIssuer`。
#   这条自愈让「搬家后跑一次 localize / 安装脚本」就能把路径拉回正位。
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

# `set -e` 的静默退出是排查黑洞：脚本半途死掉、stderr 空白。
# 任何未被 if/&& 接住的失败都把行号打到 stderr。
# 为什么用 $0 / $? 而不用中间变量：`$(basename "$0")` 是**命令替换**，
# 在同一个字符串里先展开它会把 `$?` 冲成 0（已实测），行号与退出码就都错了。
trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR


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

# 现场态目录（= `.env` 的父目录）：路径型键的「期望位置」都相对它算。
STATE_DIR = os.path.dirname(os.path.abspath(target))
# 路径型键 → 期望落点。目前只有信任锚（gwlinkd 接入时就把 CA 写在这里）。
PATH_KEYS = {"GWLINKD_TRUST_BUNDLE": os.path.join(STATE_DIR, "control-center.pem")}

# 信任锚位置如果是**空目录**，那一定是 docker 建的（源文件缺失时 bind 会被建成同名目录）：
# 这个路径上再也写不进文件，而它挂进 wparse 容器后会被当成 SSL_CERT_FILE ——
# 引擎建 HTTP 客户端失败（`build victoriametric client failed`）、容器无限重启。
# 空目录只可能是这个来历，直接删；非空的不碰（可能是现场自己放的目录）。
for expected in PATH_KEYS.values():
    if os.path.isdir(expected) and not os.listdir(expected):
        try:
            os.rmdir(expected)
            print(f"  已删除 docker 建出的空目录：{expected}（源文件缺失时 bind 会被建成目录）")
        except OSError as err:
            print(f"  [WARN] 删不掉空目录 {expected}：{err}", file=sys.stderr)


def set_line(lines, key, value):
    """把现有的 `key=` 行换成 `key=value`（保持行序）；找不到就不动。"""
    for idx, raw in enumerate(lines):
        head, sep, _ = raw.partition("=")
        if sep and head.strip() == key:
            lines[idx] = f"{key}={value}"
            return True
    return False


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
    healed = []
    dangling = []
    for key, value in DESIRED:
        current = existing.get(key)
        if current is None:
            lines.append(f"{key}={value}")
            changed = True
            continue
        if current == "" and value != "":
            set_line(lines, key, value)
            changed = True
            continue
        # 搬家自愈：非空路径指向的文件已不存在（站点换过目录），而期望位置确实有 → 改写。
        # 只对这一种形状动手：自定义路径的文件真在 → 保留；期望位置也没有 → 只告警，不猜。
        expected = PATH_KEYS.get(key)
        if expected and current and not os.path.exists(current):
            if current != expected and os.path.exists(expected):
                set_line(lines, key, expected)
                existing[key] = expected
                changed = True
                healed.append(f"{key}: {current} → {expected}")
            elif not os.path.exists(expected):
                dangling.append(f"{key}={current}")
    for item in dangling:
        print(
            f"  [WARN] {item} 指向的文件不存在，期望位置也没有；"
            f"自签中心会回落系统根（gwlinkd 会报 UnknownIssuer）",
            file=sys.stderr,
        )
    # 清死键：声明没引用的键没有任何读取方（改名后的残留 / 旧版骶架留下的）。
    declared = declared_names(declaration)
    removed = []
    if declared is not None:
        lines, removed = prune(lines, declared)
    text = "\n".join(lines) + "\n"
    if (not changed and not removed) or text == original:
        print(f"  现场态值与当前一致，跳过：{target}")
        sys.exit(0)
    notes = []
    if healed:
        notes.append("路径自愈：" + "；".join(healed))
    if removed:
        notes.append("清掉未声明的死键：" + ", ".join(sorted(set(removed))))
    note = f"（{'；'.join(notes)}）" if notes else ""
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

# ── 中心信任锚的**容器投影**（结构契约，不要改回单文件挂载）───────────────────
#
# 事故事实（2026-10-23，现场 wparse 容器 restarting 52 次）：
#   中心信任锚缺失时，compose 里“把文件挂进容器”那条 bind 会被 docker **静默建成一个同名空目录**；
#   wparse 把这个路径当 `SSL_CERT_FILE`，构造 HTTP 客户端失败（`build victoriametric client failed`），
#   进程退出、容器无限重启 —— 而采集面和 VictoriaMetrics 都是好的。
#
# 于是定下三条契约（A/B 两种中心都有、并且「中心还没接入」也成立）：
#   1. 信任锚是**可选**的：公网 CA 的中心用不到；还没接入中心时也不存在。两个状态都必须能跑。
#   2. 容器**不挂单文件**，只挂**目录** `identity/gwlinkd/trust/`（本脚本保证它存在）——
#      docker 就再也没有「把文件建成目录」的机会。
#   3. 真身仍是 `identity/gwlinkd/control-center.pem`（gwlinkd 页面接入时写的就是它，不改），
#      这里做的是**投影**：有可读 PEM 就拷过去，没有就把投影删掉（不留陈旧 CA）。
#
# 代价（写在这里免得以后又当 bug）：页面接入后新写入的 CA 要等下一次 localize /
#   升级才会投进容器。而在那之前 project_remote 本来也 clone 不动（还没接中心）。
TRUST_SRC="${DIR}/control-center.pem"
TRUST_DIR="${DIR}/trust"
TRUST_DST="${TRUST_DIR}/control-center.pem"

mkdir -p "${TRUST_DIR}"
if [[ ! -w "${TRUST_DIR}" ]]; then
  echo "  [FAIL] ${TRUST_DIR} 不可写（常见于先跑过 docker compose up，被建成 root:root）" >&2
  echo "         修法：sudo chown -R \$(id -u):\$(id -g) '${TRUST_DIR}'" >&2
  exit 1
fi
# 目录里只会有**公开**证书（CA 的公钥部分），所以 755 就够：也给得出集装箱（uid 999）
# 一个在 macOS/OrbStack 上也能进的门（那里没有 `gops sys perms` 可跑）。
chmod 755 "${TRUST_DIR}" 2>/dev/null || true

# 投影位置如果是个目录（只会是人为/旧版本留给我们的意外），先清掉空的。
if [[ -d "${TRUST_DST}" ]] && ! rmdir "${TRUST_DST}" 2>/dev/null; then
  echo "  [FAIL] ${TRUST_DST} 是目录且非空，无法投影" >&2
  exit 1
fi

if [[ -f "${TRUST_SRC}" ]] && grep -q 'BEGIN CERTIFICATE' "${TRUST_SRC}"; then
  if [[ -f "${TRUST_DST}" ]] && cmp -s "${TRUST_SRC}" "${TRUST_DST}"; then
    echo "  信任锚投影已是最新：${TRUST_DST}"
  else
    cp -f "${TRUST_SRC}" "${TRUST_DST}"
    chmod 644 "${TRUST_DST}"
    echo "  已投影中心信任锚到容器目录：${TRUST_DST}"
  fi
else
  rm -f "${TRUST_DST}"
  echo "  无中心信任锚（公网 CA 或尚未接入中心）：容器侧回落系统根（合法现场）"
fi
