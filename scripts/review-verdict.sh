#!/usr/bin/env bash
# Fetch the independent review verdict for a PR and act on it.
#
# The verdict is delivered as a PR comment from the reviewer workflow bot,
# whose login differs per API: REST issue comments report
# "github-actions[bot]" while GraphQL (gh pr view) reports "github-actions".
# We query REST and match the exact bot login, so only the reviewer bot's
# latest comment qualifies.
#
# Usage:
#   scripts/review-verdict.sh <pr-number> [--print]
#
#   --print  only print the verdict body; never merge or label
#
# Behavior:
#   VERDICT: APPROVE (line start)         -> gh pr merge --merge --delete-branch
#   VERDICT: REQUEST_CHANGES (line start) -> gh pr edit --add-label agent-failed
#   no bot comment / no verdict line      -> non-zero exit, no side effects
set -u

usage() {
  echo "usage: $0 <pr-number> [--print]" >&2
  exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
PR="$1"
case "$PR" in '' | *[!0-9]*) usage ;; esac
PRINT_ONLY=0
if [ "${2:-}" = "--print" ]; then
  PRINT_ONLY=1
elif [ $# -eq 2 ]; then
  usage
fi

REPO="${GITHUB_REPOSITORY:-}"
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 2
fi

COMMENTS=$(gh api "repos/$REPO/issues/$PR/comments")
BODY=$(printf '%s' "$COMMENTS" | node -e '
  const chunks = [];
  process.stdin.on("data", (c) => chunks.push(c));
  process.stdin.on("end", () => {
    const comments = JSON.parse(chunks.join("") || "[]")
      .filter((c) => c.user && c.user.login === "github-actions[bot]")
      .sort((a, b) => a.id - b.id);
    const last = comments[comments.length - 1];
    if (last) process.stdout.write(last.body);
  });
')

if [ -z "$BODY" ]; then
  echo "review verdict missing: no github-actions[bot] comment found on PR #$PR" >&2
  exit 3
fi

echo "最新审计结论: $BODY"

if [ "$PRINT_ONLY" -eq 1 ]; then
  exit 0
fi

if printf '%s\n' "$BODY" | grep -q '^VERDICT: APPROVE'; then
  if ! gh pr merge "$PR" --merge --delete-branch 2>/dev/null; then
    gh pr merge "$PR" --merge --delete-branch ||
      { echo "::error::merge of PR #$PR failed" >&2; exit 5; }
  fi
  echo "✅ 审计通过，已合并"
elif printf '%s\n' "$BODY" | grep -q '^VERDICT: REQUEST_CHANGES'; then
  echo "⛔ 审计未通过（REQUEST_CHANGES），已标记等待处理"
  gh pr edit "$PR" --add-label agent-failed || true
else
  echo "::error::review verdict on PR #$PR has no VERDICT: APPROVE/REQUEST_CHANGES line; not merging, not labeling" >&2
  exit 4
fi
