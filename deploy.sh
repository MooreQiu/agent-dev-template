#!/usr/bin/env bash
# 把本模板的 agent 开发体系部署进已有仓库：
#   复制体系文件 → 提交到 chore/agent-dev-template 分支 → 开 PR → 在线配置（labels/secrets/vars）
# 用法:
#   ./deploy.sh owner/name                 # 克隆远端仓库，走 PR
#   ./deploy.sh /path/to/local/repo        # 部署进本地仓库（不自动 push）
#   ./deploy.sh --preview <target>         # 只预览变更，不复制/不提交/不推送
# 环境变量:
#   ANTHROPIC_AUTH_TOKEN  提供时自动完成 secrets 配置
#   ANTHROPIC_BASE_URL    自定义端点（默认 https://open.bigmodel.cn/api/anthropic）
set -euo pipefail

PREVIEW=0
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --preview) PREVIEW=1 ;;
    -h|--help) sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^用法:/,/^环境变量:/p'; exit 0 ;;
    *)
      if [ -z "$TARGET" ]; then
        TARGET="$1"
      else
        echo "未知参数: $1（用法: ./deploy.sh [--preview] <owner/name | 本地仓库路径>）" >&2
        exit 2
      fi
      ;;
  esac
  shift
done
[ -n "$TARGET" ] || { echo "用法: ./deploy.sh [--preview] <owner/name | 本地仓库路径>" >&2; exit 1; }

SRC=$(cd "$(dirname "$0")" && pwd)
TMP=""

# Keep the last command of the trap status-neutral: under `set -e` a false
# `[ -n "$TMP" ] && ...` in local mode (TMP empty) would clobber the intended
# exit code of the whole script.
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
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

say() { printf '\n==> %s\n' "$*"; }

# 模板必要组件清单：自动化（workflows）/指令（AGENTS、CLAUDE、docs）
# /技能（.claude/skills）/启动器（.claude/commands、scripts）/安装（INSTALL、setup）
# /运行配置（.agent 与 npm 元数据：安装出的默认 .agent/project.json 声明了
# package-lock.json，缺了它们 verify-project 门会 fail-closed；消费者随后按
# INSTALL.md 把命令换成自己项目的真实值）
ITEMS=(
  AGENTS.md
  CLAUDE.md
  INSTALL.md
  .agent
  docs
  scripts
  .specify
  .claude/commands
  .claude/skills
  .github/ISSUE_TEMPLATE
  .github/PULL_REQUEST_TEMPLATE.md
  .github/workflows/claude.yml
  .github/workflows/agent-sweep.yml
  .github/workflows/pr-review.yml
  .github/workflows/review-watchdog.yml
  .github/workflows/project-sync.yml
  package.json
  package-lock.json
  setup.sh
)

# --- 预览模式：只报告会发生的变更，绝不修改目标仓库 -------------------------
if [ "$PREVIEW" -eq 1 ]; then
  say "预览部署变更到 ${REPO}（--preview：不复制、不提交、不推送、不切分支）"
  echo "  + 目标缺失（会新增）   = 与模板一致   ! 已存在且与模板不同（保留本地定制）"
  ADDED=0
  SAME=0
  CONFLICT=0
  preview_item() {
    local item="$1"
    if [ ! -e "$item" ]; then
      printf '  + %s\n' "$item"
      ADDED=$((ADDED + 1))
    elif diff -r -q "$SRC/$item" "$item" >/dev/null 2>&1; then
      printf '  = %s\n' "$item"
      SAME=$((SAME + 1))
    else
      printf '  ! %s\n' "$item"
      CONFLICT=$((CONFLICT + 1))
    fi
  }
  for item in "${ITEMS[@]}"; do
    preview_item "$item"
  done
  say "预览结果：$ADDED 新增 / $SAME 一致 / $CONFLICT 冲突"
  if [ "$CONFLICT" -gt 0 ]; then
    echo "  冲突组件在实际部署时保留本地版本（不覆盖）；要吸收模板更新请手动 diff 合并"
  fi
  exit 0
fi

DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
git fetch origin "$DEFAULT_BRANCH" 2>/dev/null || true
git checkout -B chore/agent-dev-template "origin/$DEFAULT_BRANCH" 2>/dev/null || git checkout -B chore/agent-dev-template

say "复制体系文件到 ${REPO}（已存在的一律跳过，不覆盖你的定制）"
SKIPPED=()
COPIED=()
copy_item() {
  local item="$1"
  if [ -e "$item" ]; then
    echo "  ⚠️ 已存在，跳过: $item"
    SKIPPED[${#SKIPPED[@]}]="$item"
    return
  fi
  mkdir -p "$(dirname "$item")"
  cp -R "$SRC/$item" "$item"
  COPIED[${#COPIED[@]}]="$item"
  echo "  ✓ $item"
}
for item in "${ITEMS[@]}"; do
  copy_item "$item"
done

say "提交"
if [ "${#COPIED[@]}" -gt 0 ]; then
  git add "${COPIED[@]}"
fi
if ! git diff --cached --quiet; then
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
    echo "本地模式：文件已复制并 commit，未 push。检查后执行：git push -u origin chore/agent-dev-template && gh pr create --base $DEFAULT_BRANCH"
  fi
else
  echo "  没有新文件需要提交"
fi

if [ -n "$REPO" ] && [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  say "在线配置 ${REPO}（labels/secrets/vars）"
  ( cd "$DIR" && ./setup.sh --repo="$REPO" )
else
  say "跳过在线配置"
  echo "  设置 ANTHROPIC_AUTH_TOKEN 环境变量后运行: ./setup.sh --repo=$REPO"
fi

if [ "${#SKIPPED[@]}" -gt 0 ]; then
  say "⚠️ 部署不完整：以下必要组件已存在被跳过（保留你的定制，未覆盖）"
  for item in "${SKIPPED[@]}"; do
    echo "    - $item"
  done
  echo "  请对照上游模板手动核对上述组件，必要时合并模板更新，才算部署完成"
else
  say "部署完成：全部必要组件已部署"
fi

say "剩余人工步骤（见 INSTALL.md）"
echo "  1. 网页开启: Settings → Actions → General → Workflow permissions → Allow GitHub Actions to create and approve pull requests"
echo "  2. 填写 AGENTS.md 的「项目信息」占位（构建/测试命令）"
