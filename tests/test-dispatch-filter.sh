#!/usr/bin/env bash
# Acceptance tests for issue #13: dispatch trigger filtering.
#
# Claude Dispatch must only run for human-initiated triggers. Bot activity
# (acknowledgement comments containing @claude, automated assignments, other
# bot comments) must never recursively start duplicate work.
#
# Run: bash tests/test-dispatch-filter.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="$REPO_ROOT/scripts/dispatch-filter.sh"
CLAUDE_YML="$REPO_ROOT/.github/workflows/claude.yml"

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+ -- $2}"; failures=$((failures + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$FILTER" ]; then
  fail "scripts/dispatch-filter.sh exists" "file not found"
  echo "$failures test(s) failed"
  exit 1
fi

# Runs the filter against $TMP/event.json. Sets FILTER_RC and FILTER_OUT.
run_filter() { # <event_name> [allowed_actors]
  FILTER_OUT=$(GITHUB_EVENT_NAME="$1" GITHUB_EVENT_PATH="$TMP/event.json" \
    AGENT_ALLOWED_ACTORS="${2:-}" bash "$FILTER" 2>&1)
  FILTER_RC=$?
}

expect_allow() { # <name>
  if [ "$FILTER_RC" -eq 0 ]; then
    pass "$1"
  else
    fail "$1" "rc=$FILTER_RC out=$FILTER_OUT"
  fi
}

expect_deny() { # <name>
  if [ "$FILTER_RC" -ne 0 ]; then
    pass "$1"
  else
    fail "$1" "rc=0 (allowed) out=$FILTER_OUT"
  fi
}

# --- fixtures ---

cat >"$TMP/event.json" <<'EOF'
{"action":"created","issue":{"number":13,"labels":[{"name":"bug"}]},"comment":{"body":"please @claude take this issue","user":{"login":"alice","type":"User"}},"sender":{"login":"alice","type":"User"}}
EOF
run_filter issue_comment
expect_allow "human comment mentioning @claude is allowed"

cat >"$TMP/event.json" <<'EOF'
{"action":"created","issue":{"number":13,"labels":[]},"comment":{"body":"🤖 @claude 收到，开始处理 issue #13。","user":{"login":"github-actions[bot]","type":"Bot"}},"sender":{"login":"github-actions[bot]","type":"Bot"}}
EOF
run_filter issue_comment
expect_deny "github-actions ack comment containing @claude is denied"

cat >"$TMP/event.json" <<'EOF'
{"action":"created","issue":{"number":13,"labels":[]},"comment":{"body":"🤖 @claude acknowledged","user":{"login":"agent-dev-bot[bot]","type":"Bot"}},"sender":{"login":"agent-dev-bot[bot]","type":"Bot"}}
EOF
run_filter issue_comment
expect_deny "GitHub App bot ack comment containing @claude is denied"

cat >"$TMP/event.json" <<'EOF'
{"action":"created","issue":{"number":13,"labels":[]},"comment":{"body":"human comment but no mention","user":{"login":"alice","type":"User"}},"sender":{"login":"alice","type":"User"}}
EOF
run_filter issue_comment
expect_deny "human comment without @claude mention is denied"

cat >"$TMP/event.json" <<'EOF'
{"action":"created","issue":{"number":8,"labels":[],"pull_request":{"url":"https://api.github.com/repos/o/r/pulls/8"}},"comment":{"body":"@claude please fix the failing test","user":{"login":"bob","type":"User"}},"sender":{"login":"bob","type":"User"}}
EOF
run_filter issue_comment
expect_allow "human PR review comment mentioning @claude is allowed"

cat >"$TMP/event.json" <<'EOF'
{"action":"edited","issue":{"number":13,"labels":[]},"comment":{"body":"edited to add @claude","user":{"login":"alice","type":"User"}},"sender":{"login":"alice","type":"User"}}
EOF
run_filter issue_comment
expect_deny "comment edits (action != created) are denied"

cat >"$TMP/event.json" <<'EOF'
{"action":"assigned","issue":{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"bug"}]},"assignee":{"login":"alice","type":"User"},"sender":{"login":"alice","type":"User"}}
EOF
run_filter issues
expect_allow "human assignment on ready-for-agent issue is allowed"

cat >"$TMP/event.json" <<'EOF'
{"action":"assigned","issue":{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"agent-claimed"}]},"assignee":{"login":"agent-dev-bot[bot]","type":"Bot"},"sender":{"login":"agent-dev-bot[bot]","type":"Bot"}}
EOF
run_filter issues
expect_deny "automated (bot) assignment is denied"

cat >"$TMP/event.json" <<'EOF'
{"action":"assigned","issue":{"number":5,"labels":[{"name":"bug"}]},"assignee":{"login":"alice","type":"User"},"sender":{"login":"alice","type":"User"}}
EOF
run_filter issues
expect_deny "assignment without ready-for-agent label is denied"

cat >"$TMP/event.json" <<'EOF'
{"action":"assigned","issue":{"number":5,"labels":[{"name":"ready-for-agent"}]},"assignee":{"login":"alice","type":"User"},"sender":{"login":"github-actions[bot]","type":"Bot"}}
EOF
run_filter issues
expect_deny "assignment event sent by github-actions bot is denied"

cat >"$TMP/event.json" <<'EOF'
{"ref":"refs/heads/main","sender":{"login":"alice","type":"User"}}
EOF
run_filter push
expect_deny "unhandled event types are denied"

cat >"$TMP/event.json" <<'EOF'
{"action":"created","issue":{"number":13,"labels":[]},"comment":{"body":"hi @claude","user":{"login":"carol","type":"User"}},"sender":{"login":"carol","type":"User"}}
EOF
run_filter issue_comment "alice,bob"
expect_deny "comment from caller outside AGENT_ALLOWED_ACTORS is denied"

cat >"$TMP/event.json" <<'EOF'
{"action":"created","issue":{"number":13,"labels":[]},"comment":{"body":"hi @claude","user":{"login":"Alice","type":"User"}},"sender":{"login":"Alice","type":"User"}}
EOF
run_filter issue_comment "alice,bob"
expect_allow "comment from allowlisted caller is allowed (case-insensitive)"

cat >"$TMP/event.json" <<'EOF'
{"action":"created","issue":{"number":13,"labels":[]},"comment":{"body":"hi @claude","user":{"login":"carol","type":"User"}},"sender":{"login":"carol","type":"User"}}
EOF
run_filter issue_comment ""
expect_allow "empty AGENT_ALLOWED_ACTORS allows any human caller"

rm -f "$TMP/event.json"
run_filter issue_comment
expect_deny "missing event payload is denied (fail closed)"

# --- workflow wiring ---

grep -Fq 'scripts/dispatch-filter.sh' "$CLAUDE_YML" \
  && pass "claude.yml runs scripts/dispatch-filter.sh" \
  || fail "claude.yml runs scripts/dispatch-filter.sh" "no reference found"

grep -Fq "steps.filter.outputs.result == 'allow'" "$CLAUDE_YML" \
  && pass "claude.yml gates dispatch on filter result" \
  || fail "claude.yml gates dispatch on filter result" "no step condition found"

grep -Fq 'AGENT_ALLOWED_ACTORS: ${{ vars.AGENT_ALLOWED_ACTORS }}' "$CLAUDE_YML" \
  && pass "claude.yml passes AGENT_ALLOWED_ACTORS to the filter step" \
  || fail "claude.yml passes AGENT_ALLOWED_ACTORS to the filter step" \
    "no env mapping: repo vars never reach process env without it"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
