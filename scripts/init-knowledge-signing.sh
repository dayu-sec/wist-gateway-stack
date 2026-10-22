#!/usr/bin/env bash
# 备料：知识库内容包的**验签公钥**（可选）。启用后，网关**只接受**这把钥匙签过的内容包。
#
# 与网关侧的关系（设计：wist-gateway/docs/design/knowledge-content-management.md §9）：
#   发布侧（wist-knowledge 的 CI）用私钥签 `.sig`；网关用**这里放的公钥**验。
#   公钥是公开信息（`wist-knowledge/keys/knowledge-signing.pub.pem`），与安装脚本签名密钥**不是**同一把。
#
# 幂等：公钥是"放一份、之后只读"，重复跑不会变。
#
# 用法：
#   scripts/init-knowledge-signing.sh [目标目录]        # 默认 configs/gateway
#
# 公钥从哪来（按顺序）：
#   1. env KNOWLEDGE_SIGNING_PUBKEY=<路径>              # 显式指定（现场覆盖）
#   2. <栈根>/sys/keys/knowledge-signing.pub.pem        # **随栈入库**：交付就靠这条
#   3. 同级仓 wist-knowledge 的 keys/knowledge-signing.pub.pem（本地开发布局的便利）
# 都不给/都不在  → **不启用验签**（不改任何东西；已有公钥也保持原样）
#
# 为什么要 ②：交付出去的是**栈自己**，同级没有 wist-knowledge 仓 —— 只靠 ③ 的话，
# 现场永远找不到公钥，验签默默变成关闭（2026-10-01 在 gateway-alone 上真实踩到）。
# ② 是 ③ 的副本（发布侧那把私钥的公开半边，公开信息，入库无秘密）；
# 对发布制品验过：指纹 502d6b90a96afb0b…，与 wist-knowledge v0.1.1 的 .sig 对得上。
#
# 启用 / 关掉：
#   启用：给上面任一个来源（或直接把公钥拷成 identity/gateway/public/knowledge-signing.pub.pem）→ 跑 localize
#   关掉：删掉 identity/gateway/public/knowledge-signing.pub.pem → 再跑 localize
#
# ⚠️ 启用后网关会**拒收未签名 / 验不过**的包（`package_signature_invalid`）——
#    换公钥后**必须**让发布侧用对应私钥重签、重新发布，旧包会录不进去。
set -euo pipefail

# `set -e` 的静默退出是排查黑洞：脚本半途死掉、stderr 空白。
# 任何未被 if/&& 接住的失败都把行号打到 stderr。
# 为什么用 $0 / $? 而不用中间变量：`$(basename "$0")` 是**命令替换**，
# 在同一个字符串里先展开它会把 `$?` 冲成 0（已实测），行号与退出码就都错了。
trap 'echo "$0 失败：第 ${LINENO} 行（退出码 $?）" >&2' ERR


DIR="${1:-configs/gateway}"
STACK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VALUE_JSON="${DIR}/wist-gateway.value.json"
# 验签公钥是**公开**事实，归站点身份（identity/public，dev/prod 共用），不进资源树的 state/。
TARGET="${STACK_ROOT}/identity/gateway/public/knowledge-signing.pub.pem"
VENDORED="${STACK_ROOT}/sys/keys/knowledge-signing.pub.pem"
SIBLING="${STACK_ROOT}/../wist-knowledge/keys/knowledge-signing.pub.pem"

# python3 是硬依赖（指纹计算 + 渲染值更新）；缺了要**当场**说，不能等后面无声地半途死。
command -v python3 >/dev/null 2>&1 || { echo "缺少 python3，无法计算公钥指纹 / 更新渲染值" >&2; exit 1; }

note() { echo "  $*"; }

# 指纹：公钥换没用/换错了，看这一串就明白（打印前 16 位，够区分）。
#
# 为什么不用 `openssl pkey -pubin -outform DER | shasum`（那是以前的样子）：
#   · **LibreSSL 读不了 Ed25519**：macOS 自带的 /usr/bin/openssl 是 LibreSSL，
#     `pkey -pubin` 对 Ed25519 公钥报 `unable to load Public Key`（rc=1）。
#     而升级流程由 gwlinkd 派生，PATH 里没有 Homebrew 目录 —— 恰好解析到它，
#     于是现场算出的指纹永远是空的（与 2026-10-23 那次 `x509 -ext` 事故同一个根因）。
#   · `shasum` 是 macOS 带的（Perl）；精简 Linux（无 perl / alpine）上没有。
# 直接对 PEM 里的 DER（= base64 主体）取 sha256：只需要 python3，两个平台一个结果。
fp() {
  python3 - "$1" <<'PY'
import base64, hashlib, sys

with open(sys.argv[1], encoding="ascii", errors="replace") as handle:
    body = "".join(line.strip() for line in handle if not line.startswith("-----"))
print(hashlib.sha256(base64.b64decode(body)).hexdigest()[:16])
PY
}

SRC="${KNOWLEDGE_SIGNING_PUBKEY:-}"
if [[ -z "$SRC" && -f "$VENDORED" ]]; then
  SRC="$VENDORED"
fi
if [[ -z "$SRC" && -f "$SIBLING" ]]; then
  SRC="$SIBLING"
fi

mkdir -p "$(dirname -- "${TARGET}")"

if [[ -n "$SRC" ]]; then
  [[ -f "$SRC" ]] || {
    echo "KNOWLEDGE_SIGNING_PUBKEY 指向的文件不存在：${SRC}" >&2
    exit 1
  }
  # 便宜的形状检查：别把私钥、证书或随便一个文件当公钥放进来。
  grep -q -- "-----BEGIN PUBLIC KEY-----" "$SRC" || {
    # 反引号必须转义：写成裸的 `...` 会被当成**命令替换**去执行（以前这里就是：
    # 真正跑了一次 `-----BEGIN`，报错信息变成 “line 86: -----BEGIN: command not found”）。
    echo "看起来不是 Ed25519 **公钥** PEM（缺 \`-----BEGIN PUBLIC KEY-----\`）：${SRC}" >&2
    echo "  它应是 wist-knowledge 仓的 keys/knowledge-signing.pub.pem" >&2
    exit 1
  }
  if [[ -f "$TARGET" ]] && cmp -s "$SRC" "$TARGET"; then
    note "验签公钥已就位（内容一致，跳过）：${TARGET}（来源 ${SRC}，指纹 $(fp "$TARGET")…）"
  else
    install -m 0644 "$SRC" "$TARGET"
    note "已放置验签公钥：${TARGET} ← ${SRC}（指纹 $(fp "$TARGET")…）"
  fi
elif [[ -f "$TARGET" ]]; then
  note "已有验签公钥，保持不变：${TARGET}"
else
  note "未提供验签公钥 → **不启用**知识库包验签（只记 sha256）"
fi

# 把"验签是否启用"写进渲染值：模板据此决定是否渲染 `signing_public_key_file` **那一行**
# （`[knowledge]` 段本身现在恒渲染 —— 它还带与验签无关的 `source_dir`）。
# 为什么必须与"文件真的在"严格同步：网关**配了公钥却读不到/不是公钥就会拒绝启动**
# （`infra/config.rs` 的 validate）——不同步就会造出一台上不了线的网关。
if [[ ! -f "$VALUE_JSON" ]]; then
  note "还没有 ${VALUE_JSON}（先跑 scripts/init-gateway.sh）——本轮跳过渲染值更新"
  exit 0
fi

want=""
if [[ -f "$TARGET" ]]; then
  want="identity/public/knowledge-signing.pub.pem"
fi
python3 - "$VALUE_JSON" "$want" <<'PY'
import json, os, sys, tempfile

path, want = sys.argv[1], sys.argv[2]
with open(path) as handle:
    value = json.load(handle)
if value.get("knowledge_signing_pubkey", "") == want:
    print(f"  渲染值已是 knowledge_signing_pubkey={want!r}，跳过")
    sys.exit(0)
value["knowledge_signing_pubkey"] = want
# 原子替换，并保持 0600（它装着 admin token，别因为改写把权限放宽）。
directory = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".value-", suffix=".json")
with os.fdopen(fd, "w") as handle:
    json.dump(value, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(f"  渲染值已更新：knowledge_signing_pubkey={want!r}（验签{'启用' if want else '关闭'}）")
PY
