#!/usr/bin/env bash
# Acceptance tests for issue #28: the pr-review auto-merge step must find the
# reviewer bot's verdict comment.
#
# GitHub reports the workflow bot differently per API:
#   REST issue comments -> user.login == "github-actions[bot]"
#   GraphQL (gh pr view --json comments) -> author.login == "github-actions"
# The old workflow filtered GraphQL output for "github-actions[bot]" and never
# matched, so APPROVE never merged and every PR was mislabeled agent-failed.
#
# The fix lives in scripts/review-verdict.sh (REST lookup, exact bot login)
# and is exercised here with a mocked gh CLI (no network access).
#
# Extended for issue #13: when the workflow resolves GitHub App auth
# (scripts/app-auth.sh, docs/GITHUB_APP_SETUP.md) the verdict comment comes
# from the App bot "mooreqiu-agent-dev-bot[bot]". The lookup accepts an EXACT allowlist
# of the two reviewer logins; unknown bots and humans stay ignored so no
# third-party app comment can ever drive a merge.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/review-verdict.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-test-verdict.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

GH_LOG="$TMP/gh.log"
MOCK_BIN="$TMP/bin"
mkdir -p "$MOCK_BIN"

# --- mocked gh (records every call; serves REST comments from a fixture) ---
cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
for a in "$@"; do
  case "$a" in
    repos/*/issues/*/comments)
      cat "$COMMENTS_FIXTURE"
      exit 0
      ;;
  esac
done
case "$1 $2" in
  "pr merge"|"pr edit"|"repo view") exit 0 ;;
esac
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"
export GH_LOG

failures=0
check() { # check <description> <command> [args...]
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    failures=$((failures + 1))
  fi
}

run_script() { # run_script <fixture> [script args...] -> $STATUS/$OUT/$ERR
  COMMENTS_FIXTURE="$1"
  export COMMENTS_FIXTURE
  shift
  : > "$GH_LOG"
  OUT=$(PATH="$MOCK_BIN:$PATH" GITHUB_REPOSITORY=acme/fixture \
    bash "$SCRIPT" "$@" 2>"$TMP/err.txt")
  STATUS=$?
  printf '%s\n' "$OUT" > "$TMP/out.txt"
}

no_mutations() { # no PR was merged or labeled
  ! grep -Eq 'pr (merge|edit)' "$GH_LOG"
}

# --- fixtures: REST-shaped issue comments (as gh api returns them) ---------

# Latest bot comment is the verdict; it appears FIRST in the array (highest
# id) to prove the lookup sorts by id instead of trusting array order.
# Also present: a human, the GraphQL-style suffix-less bot login, another
# app bot, and an earlier workflow bot comment.
cat > "$TMP/approve.json" <<'EOF'
[
  {"id": 104, "user": {"login": "github-actions[bot]", "type": "Bot"}, "body": "VERDICT: APPROVE — all acceptance tests verified green"},
  {"id": 103, "user": {"login": "MooreQiu", "type": "User"}, "body": "lgtm, VERDICT: APPROVE from a human"},
  {"id": 102, "user": {"login": "other-app[bot]", "type": "Bot"}, "body": "VERDICT: APPROVE from another app"},
  {"id": 101, "user": {"login": "github-actions", "type": "User"}, "body": "VERDICT: APPROVE without the [bot] suffix"},
  {"id": 100, "user": {"login": "github-actions[bot]", "type": "Bot"}, "body": "🤖 独立审计开始（peer review，与作者零上下文共享）。"}
]
EOF

# No comment from the reviewer bot at all: only a human, the GraphQL-style
# suffix-less login, and another app bot (all claiming APPROVE).
cat > "$TMP/no-bot.json" <<'EOF'
[
  {"id": 203, "user": {"login": "MooreQiu", "type": "User"}, "body": "VERDICT: APPROVE from a human"},
  {"id": 202, "user": {"login": "other-app[bot]", "type": "Bot"}, "body": "VERDICT: APPROVE from another app"},
  {"id": 201, "user": {"login": "github-actions", "type": "User"}, "body": "VERDICT: APPROVE without the [bot] suffix"}
]
EOF

: > "$TMP/empty.json"

# Latest bot comment is a multi-line REQUEST_CHANGES report.
printf '%s\n' \
'[' \
'  {"id": 302, "user": {"login": "github-actions[bot]", "type": "Bot"}, "body": "VERDICT: REQUEST_CHANGES — blocking issues:\n- tests do not cover the acceptance criteria"},' \
'  {"id": 301, "user": {"login": "github-actions[bot]", "type": "Bot"}, "body": "🤖 独立审计开始（peer review，与作者零上下文共享）。"}' \
']' > "$TMP/reject.json"

# Latest bot comment carries no VERDICT line (e.g. only the start notice).
cat > "$TMP/malformed.json" <<'EOF'
[
  {"id": 401, "user": {"login": "github-actions[bot]", "type": "Bot"}, "body": "🤖 独立审计开始（peer review，与作者零上下文共享）。"}
]
EOF

# The workflow resolved GitHub App auth, so its comments come from the App
# bot "mooreqiu-agent-dev-bot[bot]". Decoys: human, unknown app bot, and an earlier
# start notice from the GITHUB_TOKEN fallback login.
cat > "$TMP/app-bot.json" <<'EOF'
[
  {"id": 504, "user": {"login": "mooreqiu-agent-dev-bot[bot]", "type": "Bot"}, "body": "VERDICT: APPROVE — verified with the App installation token"},
  {"id": 503, "user": {"login": "MooreQiu", "type": "User"}, "body": "VERDICT: APPROVE from a human"},
  {"id": 502, "user": {"login": "other-app[bot]", "type": "Bot"}, "body": "VERDICT: APPROVE from another app"},
  {"id": 501, "user": {"login": "github-actions[bot]", "type": "Bot"}, "body": "🤖 独立审计开始（peer review，与作者零上下文共享）。"}
]
EOF

# The App bot can also deliver REQUEST_CHANGES; it must drive the label path.
printf '%s\n' \
'[' \
'  {"id": 602, "user": {"login": "mooreqiu-agent-dev-bot[bot]", "type": "Bot"}, "body": "VERDICT: REQUEST_CHANGES — blocking:\n- merge dropped the fix"},' \
'  {"id": 601, "user": {"login": "mooreqiu-agent-dev-bot[bot]", "type": "Bot"}, "body": "🤖 独立审计开始（peer review，与作者零上下文共享）。"}' \
']' > "$TMP/app-bot-reject.json"

# --- AC: APPROVE path returns the verdict body and merges ------------------
echo "== APPROVE =="
run_script "$TMP/approve.json" 42

check "exit 0 on APPROVE" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "returns the verdict body" \
  sh -c 'grep -Fq "VERDICT: APPROVE — all acceptance tests verified green" "$1"' sh "$TMP/out.txt"
check "earlier bot comment not mistaken for the verdict" \
  sh -c '! grep -Fq "独立审计开始" "$1"' sh "$TMP/out.txt"
check "human/other-bot comments ignored in the lookup" \
  sh -c '! grep -Fq "from a human" "$1" && ! grep -Fq "from another app" "$1"' sh "$TMP/out.txt"
# Squash is pinned because setup.sh requires linear history: a merge commit
# would be rejected by branch protection on every deployed repo.
check "merges the PR via squash" \
  sh -c 'grep -q "pr merge 42" "$1" && grep -q -- "--squash" "$1" && grep -q -- "--delete-branch" "$1" && ! grep -q -- " --merge " "$1"' sh "$GH_LOG"
check "does not label an approved PR" sh -c '! grep -q "pr edit" "$1"' sh "$GH_LOG"

# --- AC: human / suffix-less / other-bot authors never satisfy the lookup --
echo "== non-matching authors =="
run_script "$TMP/no-bot.json" 42

check "exit non-zero when only non-bot authors commented" \
  sh -c '[ "$1" != 0 ]' sh "$STATUS"
check "reports the verdict as missing" \
  sh -c 'grep -q "review verdict missing" "$1"' sh "$TMP/err.txt"
check "does not merge" sh -c '! grep -q "pr merge" "$1"' sh "$GH_LOG"
check "does not label (no agent-failed on missing verdict)" \
  sh -c '! grep -q "pr edit" "$1"' sh "$GH_LOG"

# --- AC: the GitHub App bot is an accepted reviewer --------------------------
echo "== GitHub App bot verdicts =="
run_script "$TMP/app-bot.json" 42

check "exit 0 on App bot APPROVE" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "returns the App bot verdict body" \
  sh -c 'grep -Fq "VERDICT: APPROVE — verified with the App installation token" "$1"' sh "$TMP/out.txt"
check "merges on the App bot verdict" \
  sh -c 'grep -q "pr merge 42" "$1" && grep -q -- "--delete-branch" "$1"' sh "$GH_LOG"
check "earlier fallback-bot comment not mistaken for the verdict" \
  sh -c '! grep -Fq "独立审计开始" "$1"' sh "$TMP/out.txt"
check "unknown app bot still ignored in the lookup" \
  sh -c '! grep -Fq "from another app" "$1"' sh "$TMP/out.txt"

run_script "$TMP/app-bot-reject.json" 42

check "exit 0 on App bot REQUEST_CHANGES" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "labels agent-failed on App bot REQUEST_CHANGES" \
  sh -c 'grep -q "pr edit 42 --add-label agent-failed" "$1"' sh "$GH_LOG"
check "does not merge an App-rejected PR" \
  sh -c '! grep -q "pr merge" "$1"' sh "$GH_LOG"

# --- AC: empty comment list is reported as missing, loudly -----------------
echo "== empty comment list =="
run_script "$TMP/empty.json" 42

check "exit non-zero on empty comment list" sh -c '[ "$1" != 0 ]' sh "$STATUS"
check "reports the verdict as missing" \
  sh -c 'grep -q "review verdict missing" "$1"' sh "$TMP/err.txt"
check "no mutation calls at all" no_mutations

# --- AC: explicit REQUEST_CHANGES labels agent-failed ----------------------
echo "== REQUEST_CHANGES =="
run_script "$TMP/reject.json" 42

check "exit 0 on REQUEST_CHANGES" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "returns the verdict body" \
  sh -c 'grep -Fq "VERDICT: REQUEST_CHANGES — blocking issues:" "$1"' sh "$TMP/out.txt"
check "labels the PR agent-failed" \
  sh -c 'grep -q "pr edit 42 --add-label agent-failed" "$1"' sh "$GH_LOG"
check "does not merge a rejected PR" sh -c '! grep -q "pr merge" "$1"' sh "$GH_LOG"

# --- AC: labeling only on an explicit verdict line -------------------------
echo "== malformed verdict =="
run_script "$TMP/malformed.json" 42

check "exit non-zero when bot comment has no VERDICT line" \
  sh -c '[ "$1" != 0 ]' sh "$STATUS"
check "explains that no verdict line was found" \
  sh -c 'grep -q "VERDICT" "$1"' sh "$TMP/err.txt"
check "no mutation calls at all" no_mutations

# --- read-only mode never mutates -------------------------------------------
echo "== print mode =="
run_script "$TMP/approve.json" 42 --print

check "exit 0 in print mode" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "print mode returns the verdict body" \
  sh -c 'grep -Fq "VERDICT: APPROVE — all acceptance tests verified green" "$1"' sh "$TMP/out.txt"
check "print mode makes no mutation calls" no_mutations

# --- workflow wiring --------------------------------------------------------
echo "== workflow wiring =="
WF="$REPO_ROOT/.github/workflows/pr-review.yml"

check "pr-review.yml auto-merge step runs review-verdict.sh" \
  sh -c 'grep -q "scripts/review-verdict.sh" "$1"' sh "$WF"
check "old GraphQL lookup removed from pr-review.yml" \
  sh -c '! grep -q "gh pr view.*--json comments" "$1"' sh "$WF"
check "verdict lookup allowlists the App bot login exactly" \
  sh -c 'grep -Fq "mooreqiu-agent-dev-bot[bot]" "$1"' sh "$SCRIPT"
check "verdict lookup never loose-matches every [bot] author" \
  sh -c '! grep -q "endswith" "$1"' sh "$SCRIPT"
check "npm test runs the full suite" \
  sh -c 'grep -q "tests/run-all.sh" "$1"' sh "$REPO_ROOT/package.json"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
