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
#   1. env KNOWLEDGE_SIGNING_PUBKEY=<路径>             # 显式指定（部署时最常用）
#   2. 同级仓 wist-knowledge 的 keys/knowledge-signing.pub.pem（本地开发布局）
#   都不给/都不在  → **不启用验签**（不改任何东西；已有公钥也保持原样）
#
# 启用 / 关掉：
#   启用：给上面任一个来源（或直接把公钥拷成 <dir>/state/knowledge-signing.pub.pem）→ 跑 localize
#   关掉：删掉 <dir>/state/knowledge-signing.pub.pem → 再跑 localize
#
# ⚠️ 启用后网关会**拒收未签名 / 验不过**的包（`package_signature_invalid`）——
#    换公钥后**必须**让发布侧用对应私钥重签、重新发布，旧包会录不进去。
set -euo pipefail

DIR="${1:-configs/gateway}"
STACK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VALUE_JSON="${DIR}/wist-gateway.value.json"
TARGET="${DIR}/state/knowledge-signing.pub.pem"
SIBLING="${STACK_ROOT}/../wist-knowledge/keys/knowledge-signing.pub.pem"

note() { echo "  $*"; }

SRC="${KNOWLEDGE_SIGNING_PUBKEY:-}"
if [[ -z "$SRC" && -f "$SIBLING" ]]; then
  SRC="$SIBLING"
fi

mkdir -p "${DIR}/state"

if [[ -n "$SRC" ]]; then
  [[ -f "$SRC" ]] || {
    echo "KNOWLEDGE_SIGNING_PUBKEY 指向的文件不存在：${SRC}" >&2
    exit 1
  }
  # 便宜的形状检查：别把私钥、证书或随便一个文件当公钥放进来。
  grep -q -- "-----BEGIN PUBLIC KEY-----" "$SRC" || {
    echo "看起来不是 Ed25519 **公钥** PEM（缺 `-----BEGIN PUBLIC KEY-----`）：${SRC}" >&2
    echo "  它应是 wist-knowledge 仓的 keys/knowledge-signing.pub.pem" >&2
    exit 1
  }
  if [[ -f "$TARGET" ]] && cmp -s "$SRC" "$TARGET"; then
    note "验签公钥已就位（内容一致，跳过）：${TARGET}"
  else
    install -m 0644 "$SRC" "$TARGET"
    note "已放置验签公钥：${TARGET}（来源 ${SRC}）"
  fi
elif [[ -f "$TARGET" ]]; then
  note "已有验签公钥，保持不变：${TARGET}"
else
  note "未提供验签公钥 → **不启用**知识库包验签（只记 sha256）"
fi

# 把"验签是否启用"写进渲染值：模板里的 `{{#if knowledge_signing_pubkey}}` 据此决定
# 是否渲染 `[knowledge]` 段。为什么改 value.json 而不是让模板恒渲染：网关**配了公钥却读不到
# 文件就拒绝启动**——"启用"必须和"文件真的在"严格同步，否则会变成一台上不了线的网关。
if [[ ! -f "$VALUE_JSON" ]]; then
  note "还没有 ${VALUE_JSON}（先跑 scripts/init-gateway.sh）——本轮跳过渲染值更新"
  exit 0
fi

want=""
[[ -f "$TARGET" ]] && want="state/knowledge-signing.pub.pem"
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
