#!/usr/bin/env bash
# 一键配置 agent-driven 开发仓库：labels、secrets、branch protection、auto-merge
# 用法：ANTHROPIC_AUTH_TOKEN=<key> ./setup.sh [--repo=owner/name] [--skip-secrets] [--skip-protection]
set -euo pipefail

REPO=""
SKIP_SECRETS=0
SKIP_PROTECTION=0
for a in "$@"; do
  case $a in
    --skip-secrets) SKIP_SECRETS=1 ;;
    --skip-protection) SKIP_PROTECTION=1 ;;
    --repo=*) REPO="${a#*=}" ;;
    *) echo "未知参数: $a"; exit 1 ;;
  esac
done
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
fi
if [ -z "$REPO" ]; then
  echo "无法推断仓库，请用 --repo=owner/name 指定"; exit 1
fi

say() { printf '\n==> %s\n' "$*"; }

say "检查 gh 认证"
gh auth status >/dev/null

say "创建/更新 labels"
label() {
  gh label create "$1" --repo "$REPO" --color "$2" --description "$3" >/dev/null 2>&1 \
    || gh label edit "$1" --repo "$REPO" --color "$2" --description "$3" >/dev/null 2>&1 \
    || echo "  ⚠️ label $1 创建失败"
  echo "  ✓ $1"
}
label ready-for-agent 1d76db "已就绪，agent 可认领（工作队列）"
label agent-claimed 5319e7 "已被 agent-sweep 认领（锁）"
label agent-failed d93f0b "agent 处理失败，已释放回队列"
label blocked b60205 "有阻塞，勿认领"

if [ "$SKIP_SECRETS" = 0 ]; then
  say "写入 secrets（Claude Code Action 需要）"
  gh secret set ANTHROPIC_BASE_URL --repo "$REPO" -b "${ANTHROPIC_BASE_URL:-https://open.bigmodel.cn/api/anthropic}"
  echo "  ✓ ANTHROPIC_BASE_URL"
  if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    gh secret set ANTHROPIC_AUTH_TOKEN --repo "$REPO" -b "$ANTHROPIC_AUTH_TOKEN"
    echo "  ✓ ANTHROPIC_AUTH_TOKEN（来自环境变量）"
  else
    printf "请粘贴 ANTHROPIC_AUTH_TOKEN（输入不回显）: "
    read -rs TOKEN
    if [ -n "$TOKEN" ]; then
      gh secret set ANTHROPIC_AUTH_TOKEN --repo "$REPO" -b "$TOKEN"
      echo -e "\n  ✓ ANTHROPIC_AUTH_TOKEN"
    else
      echo -e "\n  ⚠️ 未输入 token，跳过（Action 将无法调用模型）"
    fi
  fi
fi

if [ "$SKIP_PROTECTION" = 0 ]; then
  say "保护 main 分支（要求 PR、禁止 force push）"
  if gh api -X PUT "repos/$REPO/branches/main/protection" --input - <<'EOF' >/dev/null 2>&1
{
  "required_pull_request_reviews": { "dismiss_stale_reviews": false, "require_code_owner_reviews": false },
  "required_status_checks": { "strict": true, "contexts": [] },
  "enforce_admins": false,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true
}
EOF
  then
    echo "  ✓ branch protection 已启用"
  else
    echo "  ⚠️ 失败：GitHub Free 的私有仓库不支持 branch protection（公开仓库或付费计划可用）"
  fi

  say "启用 auto-merge"
  if gh repo edit "$REPO" --enable-auto-merge >/dev/null 2>&1; then
    echo "  ✓ auto-merge 已启用（PR 满足要求后自动合并）"
  else
    echo "  ⚠️ 失败：需要先启用带必需检查的 branch protection"
  fi
fi

say "完成 ✅"
echo "  试试：用「🤖 Agent 任务」模板开 issue（自动带 ready-for-agent）→ @claude 评论或指派触发；或等每晚 agent-sweep"
