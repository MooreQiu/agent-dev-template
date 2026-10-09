#!/usr/bin/env bash
# Acceptance tests for issue #56: detect and alert on review runs that fail
# before posting a verdict.
#
# The independent audit in pr-review.yml is an LLM session that can die before
# posting ANY verdict: a workflow-file parse error fails the run before any
# job starts (PR #38's shape, conclusion=startup_failure), and an
# infrastructure error kills the reviewer step mid-flight. The run goes red
# but nothing watches the run list, so the PR silently strands. scripts/
# review-watchdog.sh is a read-only scanner over live PR/run state with two
# bounded actions. It must detect all four silent failure modes:
#
#   no_run          open agent/* PR whose pr-review event never fired a run
#   stuck           latest pr-review run queued/in_progress far past the
#                   expected window
#   run_failed      latest pr-review run concluded failure / timed_out /
#                   startup_failure
#   repair_stalled  PR labeled agent-failed whose branch stopped moving (the
#                   issue #20 repair loop is not running)
#
# Alert comments must carry the PR number, run id/url, failure mode and a
# suggested next action, at most one per PR+mode per cooldown window, and the
# cooldown state must only count marker comments authored by the allowlisted
# reviewer bot identity (scripts/reviewer-identity.sh) -- a PR author must
# not be able to silence the watchdog by commenting the marker themselves.
# The single safe re-trigger (close+reopen, no_run mode only) is at most once
# per PR per N hours and never for PRs touching the merge-control path.
# Healthy state must be a strict no-op.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/review-watchdog.sh"
WF="$REPO_ROOT/.github/workflows/review-watchdog.yml"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-test-watchdog56.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

GH_LOG="$TMP/gh.log"
MOCK_BIN="$TMP/bin"
mkdir -p "$MOCK_BIN" "$TMP/runs" "$TMP/comments" "$TMP/files"
RUNS_DIR="$TMP/runs"
COMMENTS_DIR="$TMP/comments"
FILES_DIR="$TMP/files"
export RUNS_DIR COMMENTS_DIR FILES_DIR

# --- mocked gh (records every call; serves live state from fixtures) --------
cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ] && [ -n "${BODY_CAPTURE:-}" ]; then
    cp "$a" "$BODY_CAPTURE" 2>/dev/null
  fi
  prev="$a"
done
if [ "${1:-}" = "api" ]; then
  url="${2:-}"
  case "$url" in
    *"/pulls?state=open"*)
      cat "${PR_LIST:-/dev/null}"
      exit 0
      ;;
    *"/actions/runs?branch="*)
      branch="${url#*branch=}"
      branch="${branch%%&*}"
      f="$RUNS_DIR/${branch//\//_}.json"
      if [ -n "${RUNS_DIR:-}" ] && [ -f "$f" ]; then cat "$f"; else printf '[]\n'; fi
      exit 0
      ;;
    *"/issues/"*"/comments"*)
      n="${url#*/issues/}"
      n="${n%%/comments*}"
      f="$COMMENTS_DIR/$n.json"
      if [ -n "${COMMENTS_DIR:-}" ] && [ -f "$f" ]; then cat "$f"; else printf '[]\n'; fi
      exit 0
      ;;
    *"/pulls/"*"/files"*)
      n="${url#*/pulls/}"
      n="${n%%/files*}"
      f="$FILES_DIR/$n.json"
      if [ -n "${FILES_DIR:-}" ] && [ -f "$f" ]; then cat "$f"; else printf '[]\n'; fi
      exit 0
      ;;
  esac
  echo "mock gh: unhandled api url: $url" >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  "pr comment" | "pr close" | "pr reopen") exit 0 ;;
esac
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"
export GH_LOG
BODY_CAPTURE="$TMP/body.txt"
export BODY_CAPTURE

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

# --- fixtures ----------------------------------------------------------------

NOW=1700000000
H=3600
D=86400

PR_LIST="$TMP/prs.json"

init_fixtures() { # fresh fixture set for one scenario
  printf '[]\n' > "$PR_LIST"
  rm -f "$RUNS_DIR"/*.json "$COMMENTS_DIR"/*.json "$FILES_DIR"/*.json 2>/dev/null
  export PR_LIST
}

add_pr() { # add_pr <number> <branch> <created_epoch> <pushed_epoch|-> [labels-csv]
  node -e '
    const fs = require("fs");
    const [file, num, branch, created, pushed, labels] = process.argv.slice(1);
    const arr = JSON.parse(fs.readFileSync(file, "utf8"));
    arr.push({
      number: Number(num),
      state: "open",
      html_url: "https://github.com/acme/fixture/pull/" + num,
      created_at: new Date(Number(created) * 1000).toISOString(),
      head: {
        ref: branch,
        repo: pushed === "-" ? null : { pushed_at: new Date(Number(pushed) * 1000).toISOString() },
      },
      labels: (labels ? labels.split(",") : []).map((n) => ({ name: n })),
    });
    fs.writeFileSync(file, JSON.stringify(arr, null, 2) + "\n");
  ' "$PR_LIST" "$@"
}

add_run() { # add_run <branch> <id> <workflow-path> <status> <conclusion|-> <created_epoch> [started_epoch]
  f="$RUNS_DIR/$(printf '%s' "$1" | tr '/' '_').json"
  node -e '
    const fs = require("fs");
    const [file, branch, id, path, status, conclusion, created, started] = process.argv.slice(1);
    let data = { workflow_runs: [] };
    try { data = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {}
    data.workflow_runs.push({
      id: Number(id),
      name: "PR Review",
      path: path,
      event: "pull_request",
      status: status,
      conclusion: conclusion === "-" ? null : conclusion,
      head_branch: branch,
      html_url: "https://github.com/acme/fixture/actions/runs/" + id,
      created_at: new Date(Number(created) * 1000).toISOString(),
      run_started_at: new Date(Number(started || created) * 1000).toISOString(),
    });
    fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
  ' "$f" "$@"
}

add_comment() { # add_comment <pr> <login> <created_epoch> <body>
  f="$COMMENTS_DIR/$1.json"
  node -e '
    const fs = require("fs");
    const [file, login, created, body] = process.argv.slice(1);
    let arr = [];
    try { arr = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {}
    arr.push({
      user: { login: login },
      created_at: new Date(Number(created) * 1000).toISOString(),
      body: body,
    });
    fs.writeFileSync(file, JSON.stringify(arr, null, 2) + "\n");
  ' "$f" "$2" "$3" "$4"
}

set_files() { # set_files <pr> <filename-csv>
  node -e '
    const fs = require("fs");
    const [file, csv] = process.argv.slice(1);
    const arr = (csv ? csv.split(",") : []).map((p) => ({ filename: p }));
    fs.writeFileSync(file, JSON.stringify(arr, null, 2) + "\n");
  ' "$FILES_DIR/$1.json" "$2"
}

do_scan() { # do_scan [extra scan options...]
  : > "$GH_LOG"
  rm -f "$BODY_CAPTURE"
  OUT=$(GITHUB_REPOSITORY=acme/fixture PATH="$MOCK_BIN:$PATH" \
    bash "$SCRIPT" scan --now "$NOW" "$@" 2>"$TMP/err.txt")
  STATUS=$?
  printf '%s\n' "$OUT" > "$TMP/out.txt"
}

commented() { grep -q "pr comment $1" "$GH_LOG"; }
closed() { grep -q "pr close $1" "$GH_LOG"; }
reopened() { grep -q "pr reopen $1" "$GH_LOG"; }
no_retrigger() { ! closed "$1" && ! reopened "$1"; }
no_mutation() { ! grep -Eq 'pr (close|reopen)' "$GH_LOG"; }
no_comments() { ! grep -q "pr comment" "$GH_LOG"; }

ALERT_OF() { # ALERT_OF <mode> -> stdout marker token expected in the alert body
  printf '<!-- review-watchdog:mode=%s' "$1"
}

# --- detection: run_failed (PR #38's startup_failure shape) ------------------

echo "== detection: run_failed"
init_fixtures
add_pr 42 agent/issue-40 $((NOW - 3 * D)) $((NOW - 3 * D))
# newest first: the review run (startup_failure) plus a ci.yml noise run that
# must be ignored (path filter).
add_run agent/issue-40 9002 .github/workflows/pr-review.yml completed startup_failure $((NOW - 1 * H))
add_run agent/issue-40 9001 .github/workflows/ci.yml completed failure $((NOW - 2 * H))
do_scan

check "scan exits 0 when it finds a failed review run" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "run_failed PR gets an alert comment" commented 42
check "alert names the PR number" \
  sh -c 'grep -Fq "PR: #42" "$1"' sh "$BODY_CAPTURE"
check "alert names the failure mode" \
  sh -c 'grep -Fq "Failure mode: run_failed" "$1"' sh "$BODY_CAPTURE"
check "alert names the review run id and url" \
  sh -c 'grep -Fq "9002" "$1" && grep -Fq "actions/runs/9002" "$1"' sh "$BODY_CAPTURE"
check "alert ignores the non-review run id" \
  sh -c '! grep -Fq "9001" "$1"' sh "$BODY_CAPTURE"
check "alert suggests a next action" \
  sh -c 'grep -Fq "Suggested action:" "$1"' sh "$BODY_CAPTURE"
check "alert carries the dedup marker for its mode" \
  sh -c 'grep -Fq "review-watchdog:mode=run_failed" "$1"' sh "$BODY_CAPTURE"
check "run_failed never triggers a close/reopen" no_retrigger 42

# --- detection: no_run -> the one rate-limited re-trigger --------------------

echo "== detection: no_run"
init_fixtures
add_pr 43 agent/issue-41 $((NOW - 2 * H)) $((NOW - 2 * H))
set_files 43 "README.md,scripts/agent.sh"
do_scan

check "no_run PR gets an alert comment" commented 43
check "alert names the failure mode" \
  sh -c 'grep -Fq "Failure mode: no_run" "$1"' sh "$BODY_CAPTURE"
check "alert reports that no review run exists" \
  sh -c 'grep -Fq "Review run:" "$1" && ! grep -Fq "actions/runs/" "$1"' sh "$BODY_CAPTURE"
check "no_run PR is re-triggered via close" closed 43
check "no_run PR is re-triggered via reopen" reopened 43
check "close happens before reopen" \
  sh -c '[ "$(grep -n "pr close 43" "$1" | cut -d: -f1 | head -1)" -lt "$(grep -n "pr reopen 43" "$1" | cut -d: -f1 | head -1)" ]' \
  sh "$GH_LOG"
check "re-trigger is recorded in the alert marker" \
  sh -c 'grep -Fq "review-watchdog:action=retrigger" "$1"' sh "$BODY_CAPTURE"

# --- detection: stuck ---------------------------------------------------------

echo "== detection: stuck"
init_fixtures
add_pr 44 agent/issue-42 $((NOW - 1 * D)) $((NOW - 1 * D))
add_run agent/issue-42 9003 .github/workflows/pr-review.yml in_progress - $((NOW - 3 * H))
do_scan

check "stuck PR gets an alert comment" commented 44
check "alert names the failure mode" \
  sh -c 'grep -Fq "Failure mode: stuck" "$1"' sh "$BODY_CAPTURE"
check "alert names the stuck run id and url" \
  sh -c 'grep -Fq "9003" "$1" && grep -Fq "actions/runs/9003" "$1"' sh "$BODY_CAPTURE"
check "stuck never triggers a close/reopen" no_retrigger 44

# --- detection: repair_stalled ------------------------------------------------

echo "== detection: repair_stalled"
init_fixtures
add_pr 45 agent/issue-43 $((NOW - 8 * D)) $((NOW - 2 * D)) agent-failed
add_run agent/issue-43 9004 .github/workflows/pr-review.yml completed success $((NOW - 2 * D))
do_scan

check "stalled repair PR gets an alert comment" commented 45
check "alert names the failure mode" \
  sh -c 'grep -Fq "Failure mode: repair_stalled" "$1"' sh "$BODY_CAPTURE"
check "stalled repair never triggers a close/reopen" no_retrigger 45

# --- classification priority: a failed review run beats a stalled repair ------

echo "== classification priority"
init_fixtures
add_pr 46 agent/issue-44 $((NOW - 5 * D)) $((NOW - 2 * D)) agent-failed
add_run agent/issue-44 9005 .github/workflows/pr-review.yml completed startup_failure $((NOW - 1 * H))
do_scan

check "failed review run wins over the agent-failed label" \
  sh -c 'grep -Fq "Failure mode: run_failed" "$1"' sh "$BODY_CAPTURE"

# --- healthy state is a strict no-op ------------------------------------------

echo "== healthy: no-op"
init_fixtures
# in progress within the expected window
add_pr 47 agent/issue-45 $((NOW - 1 * D)) $((NOW - 1 * D))
add_run agent/issue-45 9006 .github/workflows/pr-review.yml in_progress - $((NOW - 10 * 60))
# verdict posted recently, no rejection label
add_pr 48 agent/issue-46 $((NOW - 1 * D)) $((NOW - 30 * 60))
add_run agent/issue-46 9007 .github/workflows/pr-review.yml completed success $((NOW - 30 * 60))
# PR too fresh for the no-run grace window
add_pr 49 agent/issue-47 $((NOW - 5 * 60)) $((NOW - 5 * 60))
# superseded run (concurrency cancel on a newer push) is not a failure
add_pr 50 agent/issue-48 $((NOW - 1 * D)) $((NOW - 1 * D))
add_run agent/issue-48 9008 .github/workflows/pr-review.yml completed cancelled $((NOW - 1 * H))
# non-agent branches are not the watchdog's business
add_pr 51 feature/manual $((NOW - 3 * D)) $((NOW - 3 * D))
add_run feature/manual 9009 .github/workflows/pr-review.yml completed startup_failure $((NOW - 1 * H))
do_scan

check "healthy scan exits 0" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "healthy scan posts no comments" no_comments
check "healthy scan never closes or reopens" no_mutation
check "non-agent branches are never queried" \
  sh -c '! grep -q "branch=feature" "$1"' sh "$GH_LOG"

# --- control-path PRs are never re-triggered ----------------------------------

echo "== rate limit: control-path PRs"
init_fixtures
add_pr 52 agent/issue-49 $((NOW - 2 * H)) $((NOW - 2 * H))
set_files 52 ".github/workflows/pr-review.yml,scripts/ci-gate.sh"
do_scan

check "control-path PR still gets its alert" commented 52
check "alert says the re-trigger is left to a human" \
  sh -c 'grep -Fq "never auto-retriggered" "$1"' sh "$BODY_CAPTURE"
check "control-path PR is never closed or reopened" no_retrigger 52

# --- alert rate limit and forged markers --------------------------------------

echo "== rate limit: alerts"
init_fixtures
add_pr 42 agent/issue-40 $((NOW - 3 * D)) $((NOW - 3 * D))
add_run agent/issue-40 9002 .github/workflows/pr-review.yml completed startup_failure $((NOW - 1 * H))

add_comment 42 "github-actions[bot]" $((NOW - 1 * H)) \
  "🕵️ review-watchdog alert
<!-- review-watchdog:mode=run_failed pr=42 run=9002 -->"
do_scan
check "a fresh bot alert marker suppresses a repeat alert" \
  sh -c '[ "$1" = 0 ] && ! commented 42' sh "$STATUS"

init_fixtures
add_pr 42 agent/issue-40 $((NOW - 3 * D)) $((NOW - 3 * D))
add_run agent/issue-40 9002 .github/workflows/pr-review.yml completed startup_failure $((NOW - 1 * H))
# forged marker: same body, but authored by the PR author -- must be ignored.
add_comment 42 "prauthor" $((NOW - 1 * H)) \
  "silence attempt
<!-- review-watchdog:mode=run_failed pr=42 run=9002 -->"
do_scan
check "a forged (non-bot) alert marker does not silence the watchdog" commented 42

init_fixtures
add_pr 42 agent/issue-40 $((NOW - 3 * D)) $((NOW - 3 * D))
add_run agent/issue-40 9002 .github/workflows/pr-review.yml completed startup_failure $((NOW - 1 * H))
# a marker for ANOTHER mode must not suppress this mode's alert.
add_comment 42 "github-actions[bot]" $((NOW - 1 * H)) \
  "<!-- review-watchdog:mode=stuck pr=42 run=9001 -->"
do_scan
check "a different mode's marker does not suppress this alert" commented 42

# --- retrigger rate limit ------------------------------------------------------

echo "== rate limit: retrigger"
init_fixtures
add_pr 43 agent/issue-41 $((NOW - 2 * H)) $((NOW - 2 * H))
set_files 43 "README.md"
add_comment 43 "github-actions[bot]" $((NOW - 2 * H)) \
  "retrigger receipt
<!-- review-watchdog:action=retrigger pr=43 -->"
do_scan
check "a recent re-trigger suppresses a second close/reopen" \
  sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "cooldown suppresses the re-trigger" no_retrigger 43
check "the alert itself is still due (first of its mode)" commented 43

# --- identity configuration via reviewer-identity.sh ---------------------------

echo "== rate limit: reviewer identity"
init_fixtures
add_pr 42 agent/issue-40 $((NOW - 3 * D)) $((NOW - 3 * D))
add_run agent/issue-40 9002 .github/workflows/pr-review.yml completed startup_failure $((NOW - 1 * H))
add_comment 42 "audit-bot[bot]" $((NOW - 1 * H)) \
  "<!-- review-watchdog:mode=run_failed pr=42 run=9002 -->"
do_scan
check "unknown bot's marker is ignored by the default allowlist" commented 42

: > "$GH_LOG"
rm -f "$BODY_CAPTURE"
OUT=$(GITHUB_REPOSITORY=acme/fixture AGENT_REVIEWER_BOT_LOGIN=audit-bot[bot] \
  PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" scan --now "$NOW" 2>"$TMP/err.txt")
STATUS=$?
check "configured AGENT_REVIEWER_BOT_LOGIN's marker suppresses the alert" \
  sh -c '[ "$1" = 0 ] && ! commented 42' sh "$STATUS"

# --- tunable thresholds ---------------------------------------------------------

echo "== thresholds"
init_fixtures
add_pr 44 agent/issue-42 $((NOW - 1 * D)) $((NOW - 1 * D))
add_run agent/issue-42 9003 .github/workflows/pr-review.yml in_progress - $((NOW - 30 * 60))
do_scan
check "in-progress run inside the default window is healthy" \
  sh -c '[ "$1" = 0 ] && ! commented 44' sh "$STATUS"
do_scan --stuck-minutes 20
check "the stuck threshold is tunable" \
  sh -c 'grep -Fq "Failure mode: stuck" "$1"' sh "$BODY_CAPTURE"

init_fixtures
add_pr 49 agent/issue-47 $((NOW - 10 * 60)) $((NOW - 10 * 60))
do_scan
check "PR inside the no-run grace window is healthy" \
  sh -c '[ "$1" = 0 ] && ! commented 49' sh "$STATUS"
do_scan --no-run-grace-minutes 5
check "the no-run grace window is tunable" \
  sh -c 'grep -Fq "Failure mode: no_run" "$1"' sh "$BODY_CAPTURE"

# --- one scan handles a mixed queue ---------------------------------------------

echo "== mixed scan"
init_fixtures
add_pr 60 agent/issue-60 $((NOW - 3 * D)) $((NOW - 3 * D))
add_run agent/issue-60 9100 .github/workflows/pr-review.yml completed startup_failure $((NOW - 1 * H))
add_pr 61 agent/issue-61 $((NOW - 2 * H)) $((NOW - 2 * H))
add_pr 62 agent/issue-62 $((NOW - 1 * D)) $((NOW - 1 * D))
add_run agent/issue-62 9101 .github/workflows/pr-review.yml in_progress - $((NOW - 10 * 60))
do_scan

check "mixed scan exits 0" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "the failed PR gets its alert" commented 60
check "the never-reviewed PR gets re-triggered" \
  sh -c 'grep -q "pr close 61" "$1" && grep -q "pr reopen 61" "$1"' sh "$GH_LOG"
check "the healthy PR is left alone" \
  sh -c '! commented 62 && ! closed 62 && ! reopened 62'

# --- usage and failure modes -----------------------------------------------------

echo "== usage"
OUT=$(GITHUB_REPOSITORY=acme/fixture PATH="$MOCK_BIN:$PATH" \
  bash "$SCRIPT" status --now "$NOW" 2>"$TMP/err.txt")
check "unknown mode is a usage error (exit 2)" sh -c '[ "$1" = 2 ]' sh "$?"
OUT=$(GITHUB_REPOSITORY=acme/fixture PATH="$MOCK_BIN:$PATH" \
  bash "$SCRIPT" scan --bogus 1 2>"$TMP/err.txt")
check "unknown option is a usage error (exit 2)" sh -c '[ "$1" = 2 ]' sh "$?"
OUT=$(env -u GITHUB_REPOSITORY PATH="$MOCK_BIN:$PATH" \
  bash "$SCRIPT" scan --now "$NOW" 2>"$TMP/err.txt")
check "unresolvable repository fails loudly (exit 1)" sh -c '[ "$1" = 1 ]' sh "$?"
OUT=$(GITHUB_REPOSITORY=acme/fixture PATH="$MOCK_BIN:$PATH" \
  bash "$SCRIPT" scan --now not-an-epoch 2>"$TMP/err.txt")
check "invalid --now epoch is rejected" sh -c '[ "$1" != 0 ]' sh "$?"

# --- workflow and wiring ----------------------------------------------------------

echo "== workflow wiring"

check "watchdog workflow exists" test -f "$WF"
check "watchdog runs on a schedule" \
  sh -c 'grep -Eq "cron:" "$1" && grep -Fq "workflow_dispatch" "$1"' sh "$WF"
check "watchdog script is invoked in scan mode" \
  sh -c 'grep -Fq "scripts/review-watchdog.sh scan" "$1"' sh "$WF"
check "watchdog workflow derives the node pin from project config" \
  sh -c 'grep -Fq "id: node_pin" "$1" && grep -Fq "runtime.version" "$1"' sh "$WF"
check "watchdog workflow keeps the derived node-version" \
  sh -c 'grep -qF "node-version: \${{ steps.node_pin.outputs.version }}" "$1"' sh "$WF"
check "watchdog workflow bootstraps the pinned environment" \
  sh -c 'grep -Fq "scripts/bootstrap-env.sh" "$1"' sh "$WF"
check "watchdog workflow acts under the resolved App identity" \
  sh -c 'grep -Fq "scripts/app-auth.sh" "$1"' sh "$WF"
check "watchdog workflow plumbs the reviewer bot login variable" \
  sh -c 'grep -Fq "AGENT_REVIEWER_BOT_LOGIN" "$1"' sh "$WF"
check "watchdog runs do not overlap each other" \
  sh -c 'grep -Fq "group: review-watchdog" "$1"' sh "$WF"
check "watchdog is deployed as a template component" \
  sh -c 'grep -Fq ".github/workflows/review-watchdog.yml" "$1"' sh "$REPO_ROOT/deploy.sh"
check "watchdog never merges anything" \
  sh -c '! grep -q "pr merge" "$1"' sh "$SCRIPT"
check "watchdog dedup state only trusts the reviewer bot identity" \
  sh -c 'grep -Fq "reviewer-identity.sh" "$1"' sh "$SCRIPT"
check "watchdog mirrors the merge-control path patterns" \
  sh -c 'grep -Fq "CONTROL_PATH_RE" "$1" && grep -Fq "github/workflows/pr-review" "$1" && grep -Fq "scripts/ci-gate" "$1" && grep -Fq "scripts/app-auth" "$1" && grep -Fq "scripts/review-verdict" "$1"' \
  sh "$SCRIPT"
check "README documents the watchdog component" \
  sh -c 'grep -Fq "review-watchdog" "$1"' sh "$REPO_ROOT/README.md"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
