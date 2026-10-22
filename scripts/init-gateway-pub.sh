#!/usr/bin/env bash
# 生成/补齐**接口层**（现场态）配置 `identity/gateway/public/wist-gateway-pub.toml`。
#
# 为什么单独一份（设计）：
#   主配置 `wist-gateway.toml` 是**交付物**（模板渲染，升级 / 重渲会覆盖）；
#   而"这台网关**对外是什么**"（对外基址 / 归属）是**现场选择** —— 它**不该被重渲动到**。
#   分开之后：现场态声明才有**唯一对象** —— 本文件在 `sys-prj.yml: contract` 里声明（对外契约，
#   声明即自动 protect + backup）；迁移 / 交付只需带它（+ 身份 PEM，见 sys-prj.yml 的 backup）。
#   网关加载时读**两份**（wist-gateway 的 `load_from_path`：段可以重合，**叶子键不许重复**）。
#
# 幂等：**按缺补齐** —— 已存在的键**一律保留**（现场可能改过），只补缺的；内容没变就不碰文件。
#   所以本脚本**可以每次 localize 都跑**，它永远不会覆盖现场值。
#
# 用法：
#   scripts/init-gateway-pub.sh [目标目录]        # 默认 identity/gateway/public
#
# 读合并后的系统变量（gops 以环境变量注入本子进程；见 sys/setting/vars.yml）：
#   WEB_DOMAIN   对外域名 → `public_base_url = https://<域>`
#
# 归属（`tenant_id` / `environment_id`）**不从变量取**：它们是**现场自己编辑本文件**的东西
# （本脚本只在缺键时用缺省值种一颗），所以不会"变量改了一份、文件又是另一份"。
set -euo pipefail

# `set -e` 的静默退出是排查黑洞：脚本半途死掉、stderr 空白。
# 任何未被 if/&& 接住的失败都把行号打到 stderr。
# 为什么用 $0 / $? 而不用中间变量：`$(basename "$0")` 是**命令替换**，
# 在同一个字符串里先展开它会把 `$?` 冲成 0（已实测），行号与退出码就都错了。
trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR


DIR="${1:-identity/gateway/public}"
OUT="${DIR}/wist-gateway-pub.toml"

command -v python3 >/dev/null 2>&1 || { echo "缺少 python3，无法生成 ${OUT}" >&2; exit 1; }
mkdir -p "$DIR"

# 用 python3 做"按键补齐"（值可能含特殊字符，不走 shell 转义）。
python3 - "$OUT" "${WEB_DOMAIN:-}" <<'PY'
import os, re, sys, tempfile

out, domain = sys.argv[1:3]

# 缺省归属：与模板原先的字面量一致（现场直接改本文件即可，不必动栈内任何东西）。
desired = [
    ("server", "public_base_url", f"https://{domain}" if domain else ""),
    ("agent", "tenant_id", "tenant-default"),
    ("agent", "environment_id", "env-default"),
]

text = ""
if os.path.exists(out):
    with open(out, encoding="utf-8") as handle:
        text = handle.read()
lines = text.splitlines()


def find_section(name):
    header = f"[{name}]"
    for index, line in enumerate(lines):
        if line.strip() == header:
            return index
    return None


def key_present(section_index, key):
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for line in lines[section_index + 1:]:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            return False
        if pattern.match(line):
            return True
    return False


changed = False
for section, key, value in desired:
    # 没有域名时不写空串 —— 让网关以"缺 public_base_url"明确报错，而不是拿一个空 URL 去对外。
    if not value:
        continue
    index = find_section(section)
    if index is None:
        if lines and lines[-1].strip() != "":
            lines.append("")
        lines.append(f"[{section}]")
        index = len(lines) - 1
        changed = True
    if key_present(index, key):
        continue  # 现场已有 → 原样保留
    lines.insert(index + 1, f'{key} = "{value}"')
    changed = True

if not changed and os.path.exists(out):
    print(f"  接口层配置已是所需形态，跳过：{out}")
    sys.exit(0)

text_out = "\n".join(lines).rstrip("\n") + "\n"
directory = os.path.dirname(os.path.abspath(out))
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".pub-", suffix=".toml")
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write(text_out)
os.chmod(tmp, 0o644)
os.replace(tmp, out)
print(f"  已写接口层配置：{out}（对外基址 / 归属）")
PY
