#!/usr/bin/env bash
# 把本模板的 agent 开发体系部署进已有仓库：
#   复制体系文件 → 提交到 chore/agent-dev-template 分支 → 开 PR → 在线配置（labels/secrets/vars）
# 用法:
#   ./deploy.sh owner/name                 # 克隆远端仓库，走 PR
#   ./deploy.sh /path/to/local/repo        # 部署进本地仓库（不自动 push）
# 环境变量:
#   ANTHROPIC_AUTH_TOKEN  提供时自动完成 secrets 配置
#   ANTHROPIC_BASE_URL    自定义端点（默认 https://open.bigmodel.cn/api/anthropic）
set -euo pipefail

TARGET="${1:?用法: ./deploy.sh <owner/name | 本地仓库路径>}"
SRC=$(cd "$(dirname "$0")" && pwd)
TMP=""

cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

if [ -d "$TARGET" ]; then
  MODE=local
  DIR=$(cd "$TARGET" && pwd)
  REPO=$(cd "$DIR" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
else
  MODE=remote
  REPO="$TARGET"
  TMP=$(mktemp -d)
  DIR="$TMP/repo"
  gh repo clone "$REPO" "$DIR" -- --depth=50 --no-tags
fi

cd "$DIR"
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
git fetch origin "$DEFAULT_BRANCH" 2>/dev/null || true
git checkout -B chore/agent-dev-template "origin/$DEFAULT_BRANCH" 2>/dev/null || git checkout -B chore/agent-dev-template

say() { printf '\n==> %s\n' "$*"; }

say "复制体系文件到 ${REPO}（已存在的一律跳过，不覆盖你的定制）"
copy_item() {
  local item="$1"
  if [ -e "$item" ]; then
    echo "  ⚠️ 已存在，跳过: $item"
    return
  fi
  mkdir -p "$(dirname "$item")"
  cp -R "$SRC/$item" "$item"
  echo "  ✓ $item"
}
copy_item AGENTS.md
copy_item docs
copy_item scripts
copy_item .specify
copy_item .claude/commands
copy_item .claude/skills
copy_item .github/ISSUE_TEMPLATE
copy_item .github/PULL_REQUEST_TEMPLATE.md
copy_item .github/workflows/claude.yml
copy_item .github/workflows/agent-sweep.yml
copy_item setup.sh

say "提交"
git add AGENTS.md .specify .claude .github setup.sh
if git diff --cached --quiet; then
  echo "没有任何文件被复制/变更，退出"
  exit 0
fi
git commit -m "Add agent-driven development template (issue queue, TDD, spec-kit, auto-claim workflows)"
echo "  ✓ commit 完成"

if [ "$MODE" = "remote" ]; then
  say "推送并创建 PR"
  git push -u origin chore/agent-dev-template
  gh pr create --base "$DEFAULT_BRANCH" --head chore/agent-dev-template \
    --title "Add agent-driven development template" \
    --body "部署自 [agent-dev-template](https://github.com/MooreQiu/agent-dev-template)。合并后按 INSTALL.md 完成剩余配置（网页开关 + AGENTS.md 项目信息）。"
  echo "  ✓ PR 已创建"
else
  echo "本地模式：文件已复制并 commit，未 push。检查后执行：git push -u origin chore/agent-dev-template && gh pr create"
fi

if [ -n "$REPO" ] && [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  say "在线配置 ${REPO}（labels/secrets/vars）"
  ( cd "$DIR" && ./setup.sh --repo="$REPO" )
else
  say "跳过在线配置"
  echo "  设置 ANTHROPIC_AUTH_TOKEN 环境变量后运行: ./setup.sh --repo=$REPO"
fi

say "部署完成（剩余两步见 INSTALL.md）"
echo "  1. 网页开启: Settings → Actions → General → Workflow permissions → Allow GitHub Actions to create and approve pull requests"
echo "  2. 填写 AGENTS.md 的「项目信息」占位（构建/测试命令）"
