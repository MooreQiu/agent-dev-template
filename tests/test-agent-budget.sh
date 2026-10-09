#!/usr/bin/env bash
# Acceptance tests for issue #22: enforce autonomous run budgets and
# expose durable progress and blockers.
#
# Covers:
#   - AC1: project-wide limits (retries, repair rounds, convergence
#     rounds, elapsed time, pipeline steps) configured in
#     .agent/budgets.json, validated and fail-closed on bad config
#   - AC2: pre-run and between-stage limit checks with a persisted
#     budget-exhausted outcome that keeps resumable state (partial
#     branch pushed)
#   - AC3: durable repository-visible status (refs/agent-status/<key>)
#     exposing spec revision, task, PR, execution phase, attempts and
#     last failure
#   - AC4: explicit pause/resume/cancel controls (issue labels) and
#     safe recovery: attempts are burned durably, interrupted runs
#     never double-execute (claim) and never retry forever (caps)
#   - AC5: repository-native markdown summaries for blockers; no
#     external notifications anywhere
#   - AC6: tests for budget exhaustion, duplicate execution,
#     pause/resume, cancellation, recoverable failures, and final
#     summary accuracy
#
# Run: bash tests/test-agent-budget.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUDGET="$REPO_ROOT/scripts/agent-budget.sh"
CLAIM="$REPO_ROOT/scripts/agent-claim.sh"
TASK="$REPO_ROOT/scripts/agent-task.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/adt-budget.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1${2:+ -- $2}"; failures=$((failures + 1)); }
check() { # check <description> <command...>
  d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

BUDGETS_TPL="$WORK/budgets-default.json"
cat > "$BUDGETS_TPL" <<'EOF'
{
  "max_attempts_per_issue": 3,
  "max_repair_rounds": 3,
  "max_convergence_rounds": 2,
  "max_elapsed_seconds_per_run": 10800,
  "max_steps_per_run": 8
}
EOF

TIGHT_BUDGETS="$WORK/budgets-tight.json"
cat > "$TIGHT_BUDGETS" <<'EOF'
{
  "max_attempts_per_issue": 3,
  "max_repair_rounds": 3,
  "max_convergence_rounds": 2,
  "max_elapsed_seconds_per_run": 10800,
  "max_steps_per_run": 1
}
EOF

ONE_SHOT_BUDGETS="$WORK/budgets-one-shot.json"
cat > "$ONE_SHOT_BUDGETS" <<'EOF'
{
  "max_attempts_per_issue": 1,
  "max_repair_rounds": 3,
  "max_convergence_rounds": 2,
  "max_elapsed_seconds_per_run": 10800,
  "max_steps_per_run": 1
}
EOF

TWO_SHOT_BUDGETS="$WORK/budgets-two-shot.json"
cat > "$TWO_SHOT_BUDGETS" <<'EOF'
{
  "max_attempts_per_issue": 2,
  "max_repair_rounds": 3,
  "max_convergence_rounds": 2,
  "max_elapsed_seconds_per_run": 10800,
  "max_steps_per_run": 8
}
EOF

FAST_CLOCK_BUDGETS="$WORK/budgets-fast-clock.json"
cat > "$FAST_CLOCK_BUDGETS" <<'EOF'
{
  "max_attempts_per_issue": 3,
  "max_repair_rounds": 3,
  "max_convergence_rounds": 2,
  "max_elapsed_seconds_per_run": 3,
  "max_steps_per_run": 8
}
EOF

BAD_BUDGETS="$WORK/budgets-bad.json"
cat > "$BAD_BUDGETS" <<'EOF'
{
  "max_attempts_per_issue": "three",
  "max_repair_rounds": 3,
  "max_convergence_rounds": 2,
  "max_elapsed_seconds_per_run": 10800,
  "max_steps_per_run": 8
}
EOF

# ===========================================================================
# AC1: limits configuration
# ===========================================================================
echo "== limits configuration"

check "budget engine exists (scripts/agent-budget.sh)" test -f "$BUDGET"
check "project budgets file exists (.agent/budgets.json)" \
  test -f "$REPO_ROOT/.agent/budgets.json"
for k in max_attempts_per_issue max_repair_rounds max_convergence_rounds \
         max_elapsed_seconds_per_run max_steps_per_run; do
  check "project budgets configure $k" grep -Fq "\"$k\":" "$REPO_ROOT/.agent/budgets.json"
done

LIMITS_OUT="$(AGENT_BUDGET_FILE="$BUDGETS_TPL" bash "$BUDGET" limits 2>&1)"
check "limits prints the retry budget" \
  sh -c 'printf "%s" "$1" | grep -Fq "max_attempts_per_issue=3"' sh "$LIMITS_OUT"
check "limits prints the repair budget" \
  sh -c 'printf "%s" "$1" | grep -Fq "max_repair_rounds=3"' sh "$LIMITS_OUT"
check "limits prints the convergence policy" \
  sh -c 'printf "%s" "$1" | grep -Fq "max_convergence_rounds=2"' sh "$LIMITS_OUT"
check "limits prints the elapsed-time budget" \
  sh -c 'printf "%s" "$1" | grep -Fq "max_elapsed_seconds_per_run=10800"' sh "$LIMITS_OUT"
check "limits prints the step budget" \
  sh -c 'printf "%s" "$1" | grep -Fq "max_steps_per_run=8"' sh "$LIMITS_OUT"

check "limit prints a single value" \
  sh -c 'test "$(AGENT_BUDGET_FILE="$2" bash "$1" limit max_steps_per_run)" = 8' \
  sh "$BUDGET" "$BUDGETS_TPL"
check "defaults apply when no budgets file exists" \
  sh -c 'test "$(AGENT_BUDGET_FILE="$2/missing.json" bash "$1" limit max_attempts_per_issue)" = 3' \
  sh "$BUDGET" "$WORK"
check "invalid budgets fail closed (limits errors)" \
  sh -c '! AGENT_BUDGET_FILE="$2" bash "$1" limits' sh "$BUDGET" "$BAD_BUDGETS"
check "invalid budgets fail closed (check errors, never allows a run)" \
  sh -c '! AGENT_BUDGET_FILE="$3" bash "$1" check "$2"' sh "$BUDGET" 22 "$BAD_BUDGETS"

# ===========================================================================
# mocked gh + fixture repository
# ===========================================================================

MOCK_BIN="$WORK/mock-bin"
GH_LOG="$WORK/gh.log"
GH_STATE="$WORK/gh-state"
mkdir -p "$MOCK_BIN" "$GH_STATE/issue" "$GH_STATE/pr"
export GH_LOG GH_STATE
printf '1\n' > "$GH_STATE/next-pr"

cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
cmd="${1:-} ${2:-}"
case "$cmd" in
  "issue view")
    cat "$GH_STATE/issue/$3.json"
    exit 0
    ;;
  "pr view")
    if [ -f "$GH_STATE/pr/$3.json" ]; then
      f="$GH_STATE/pr/$3.json"
      for a in "$@"; do
        [ "$a" = ".body" ] || continue
        sed -n 's/^.*"body": *"\([^"]*\)".*$/\1/p' "$f"
        exit 0
      done
      cat "$f"
      exit 0
    fi
    echo "no pull request found for $3" >&2
    exit 1
    ;;
  "pr create")
    if [ -f "$GH_STATE/deny-create" ]; then
      echo "mock: PR creation denied" >&2
      exit 1
    fi
    head=""
    body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --head) head="$2" ;;
        --body) body="$2" ;;
      esac
      shift
    done
    if [ -f "$GH_STATE/pr/$head.json" ]; then
      echo "mock: pull request already exists for $head" >&2
      exit 1
    fi
    n="$(cat "$GH_STATE/next-pr")"
    printf '%s\n' "$((n + 1))" > "$GH_STATE/next-pr"
    mkdir -p "$(dirname "$GH_STATE/pr/$head.json")"
    printf '{"number":%s,"state":"OPEN","url":"https://fixture/pr/%s","body":"%s"}\n' \
      "$n" "$n" "$body" > "$GH_STATE/pr/$head.json"
    echo "https://fixture/pr/$n"
    exit 0
    ;;
  "pr edit")
    all="$*"
    n=""
    body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body) body="$2" ;;
        [0-9]*) [ -z "$n" ] && n="$1" ;;
      esac
      shift
    done
    printf '%s\n' "$all" >> "$GH_STATE/pr-edit-$n.args"
    for f in "$GH_STATE"/pr/*.json "$GH_STATE"/pr/*/*.json; do
      [ -f "$f" ] || continue
      grep -Fq "\"number\":$n," "$f" || continue
      head="$(sed -n 's/^\(.*"body":\).*/\1/p' "$f")"
      printf '%s "%s"}\n' "$head" "$body" > "$f"
    done
    exit 0
    ;;
  "issue edit"|"issue comment")
    exit 0
    ;;
esac
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"

export PATH="$MOCK_BIN:$PATH"
export GITHUB_REPOSITORY=acme/fixture

issue_json() { # issue_json <n> [labels csv]
  labels="${2:-}"
  if [ -n "$labels" ]; then
    ljson=""
    oldifs="$IFS"
    IFS=','
    for l in $labels; do
      [ -n "$ljson" ] && ljson="$ljson,"
      ljson="$ljson{\"name\":\"$l\"}"
    done
    IFS="$oldifs"
    printf '{"number":%s,"title":"fixture issue %s","state":"OPEN","labels":[%s]}\n' \
      "$1" "$1" "$ljson" > "$GH_STATE/issue/$1.json"
  else
    printf '{"number":%s,"title":"fixture issue %s","state":"OPEN"}\n' "$1" "$1" \
      > "$GH_STATE/issue/$1.json"
  fi
}

make_fixture() { # make_fixture <name> [budgets-file]
  d="$WORK/$1"
  mkdir -p "$d/origin" "$d/src/scripts" "$d/src/tests" "$d/src/.agent"
  git init -q --bare "$d/origin/origin.git"
  git -C "$d/origin/origin.git" symbolic-ref HEAD refs/heads/main
  cp "$CLAIM" "$d/src/scripts/agent-claim.sh"
  cp "$TASK" "$d/src/scripts/agent-task.sh"
  cp "$BUDGET" "$d/src/scripts/agent-budget.sh"
  cat > "$d/src/tests/run-all.sh" <<'RUN'
#!/bin/sh
set -u
cd "$(dirname "$0")/.."
status=0
for t in tests/test*.sh; do
  [ -e "$t" ] || continue
  bash "$t" || status=1
done
exit "$status"
RUN
  printf '#!/bin/sh\necho ok\n' > "$d/src/tests/test-ok.sh"
  cat > "$d/src/.agent/project.json" <<'CFG'
{
  "commands": {
    "install": "",
    "build": "",
    "test": "bash tests/run-all.sh",
    "lint": "",
    "typecheck": ""
  }
}
CFG
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    cp "$2" "$d/src/.agent/budgets.json"
  fi
  git -C "$d/src" init -q
  git -C "$d/src" add -A
  git -C "$d/src" commit -qm "baseline"
  git -C "$d/src" remote add origin "$d/origin/origin.git"
  git -C "$d/src" push -q origin HEAD:refs/heads/main
  git clone -q "$d/origin/origin.git" "$d/runner"
  git -C "$d/runner" config user.name runner
  git -C "$d/runner" config user.email runner@example.com
}

claim_sha() { # claim_sha <name> <key>
  git ls-remote "$WORK/$1/origin/origin.git" "refs/agent-claims/$2" \
    | sed -n "s/^\([0-9a-f]*\).*/\1/p"
}

status_json() { # status_json <name> <key>
  ( cd "$WORK/$1/runner" && bash "$WORK/$1/runner/scripts/agent-budget.sh" show "$2" 2>/dev/null )
}

status_field() { # status_field <name> <key> <field>
  st="$(status_json "$1" "$2")"
  case "$3" in
    attempts|repair_rounds|pr|started_at|updated_at)
      printf '%s' "$st" | sed -n "s/.*\"$3\":\([0-9][0-9]*\).*/\1/p" | sed -n 1p ;;
    *)
      printf '%s' "$st" | sed -n "s/.*\"$3\":\"\([^\"]*\)\".*/\1/p" ;;
  esac
}

task() { # task <name> <key> [args...] -- <harness command...>
  d="$WORK/$1"; shift
  key="$1"; shift
  ( cd "$d/runner" && bash "$d/runner/scripts/agent-task.sh" run "$key" "$@" )
}

latest_outcome() { # latest_outcome <name> <key>
  ls "$WORK/$1/runner/.agent/runs"/task-"$2"-*.json 2>/dev/null | tail -1
}

# ===========================================================================
# AC3: durable repository-visible status
# ===========================================================================
echo "== durable status"

make_fixture status
issue_json 70
( cd "$WORK/status/runner" && bash scripts/agent-budget.sh record 70 \
    --field phase=executing --field "last_failure=artifact verification failed" \
    --field spec_revision=abc1234 --field pr=5 ) >/dev/null 2>&1
ST="$(status_json status 70)"
check "record persists status to a repository ref" test -n "$ST"
check "status exposes the task" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"task\":\"issue #70\""' sh "$ST"
check "status exposes the execution phase" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"phase\":\"executing\""' sh "$ST"
check "status exposes attempts" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"attempts\":"' sh "$ST"
check "status exposes the last failure" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"last_failure\":\"artifact verification failed\""' sh "$ST"
check "status exposes the PR" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"pr\":5"' sh "$ST"
check "status exposes the spec revision" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"spec_revision\":\"abc1234\""' sh "$ST"

( cd "$WORK/status/runner" && bash scripts/agent-budget.sh record 70 \
    --field attempts=+1 --field repair_rounds=+1 ) >/dev/null 2>&1
check "numeric fields increment durably" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"attempts\":1" && printf "%s" "$1" | grep -Fq "\"repair_rounds\":1"' \
  sh "$(status_json status 70)"
check "attempt increments record a start time" \
  sh -c 'printf "%s" "$1" | grep -Eq "\"started_at\":[1-9]"' sh "$(status_json status 70)"
check "show of an unknown key reports absence" \
  sh -c '! ( cd "$1/runner" && bash scripts/agent-budget.sh show 99999 >/dev/null 2>&1 )' \
  sh "$WORK/status"

SUMMARY="$( ( cd "$WORK/status/runner" && bash scripts/agent-budget.sh summary 70 2>/dev/null) )"
check "summary names the task" \
  sh -c 'printf "%s" "$1" | grep -Fq "issue #70"' sh "$SUMMARY"
check "summary reports the phase" \
  sh -c 'printf "%s" "$1" | grep -Fq "executing"' sh "$SUMMARY"
check "summary reports attempts against the budget" \
  sh -c 'printf "%s" "$1" | grep -Fq "Attempts: 1/3"' sh "$SUMMARY"
check "summary reports repair rounds against the budget" \
  sh -c 'printf "%s" "$1" | grep -Fq "Repair rounds: 1/3"' sh "$SUMMARY"
check "summary reports the PR" \
  sh -c 'printf "%s" "$1" | grep -Fq "#5"' sh "$SUMMARY"
check "summary reports the spec revision" \
  sh -c 'printf "%s" "$1" | grep -Fq "abc1234"' sh "$SUMMARY"
check "summary reports the last failure" \
  sh -c 'printf "%s" "$1" | grep -Fq "artifact verification failed"' sh "$SUMMARY"

# ===========================================================================
# AC2/AC4: pre-run checks and human controls
# ===========================================================================
echo "== pre-run checks"

check "fresh task is within budget" \
  sh -c '( cd "$1/runner" && bash scripts/agent-budget.sh check 71 ); test $? -eq 0' sh "$WORK/status"

( cd "$WORK/status/runner" && bash scripts/agent-budget.sh record 71 --field attempts=+1 \
    --field attempts=+1 --field attempts=+1 ) >/dev/null 2>&1
( cd "$WORK/status/runner" && bash scripts/agent-budget.sh check 71 ) > "$WORK/status/check6.out" 2>&1
check "attempts at the cap stop the run (rc 6)" test $? -eq 6
check "exhaustion message names the attempts budget" \
  grep -Fq "max_attempts_per_issue" "$WORK/status/check6.out"

( cd "$WORK/status/runner" && bash scripts/agent-budget.sh record 72 --field repair_rounds=+1 \
    --field repair_rounds=+1 --field repair_rounds=+1 ) >/dev/null 2>&1
( cd "$WORK/status/runner" && bash scripts/agent-budget.sh check 72 ) > "$WORK/status/checkr.out" 2>&1
check "repair rounds at the cap stop the run (rc 6)" test $? -eq 6
check "exhaustion message names the repair budget" \
  grep -Fq "max_repair_rounds" "$WORK/status/checkr.out"

issue_json 73 agent-paused
( cd "$WORK/status/runner" && bash scripts/agent-budget.sh check 73 ) > "$WORK/status/checkp.out" 2>&1
check "agent-paused label stops the run (rc 7)" test $? -eq 7
check "pause message names the control" \
  grep -Fq "agent-paused" "$WORK/status/checkp.out"

issue_json 74 agent-cancelled
( cd "$WORK/status/runner" && bash scripts/agent-budget.sh check 74 ) > "$WORK/status/checkc.out" 2>&1
check "agent-cancelled label stops the run (rc 7)" test $? -eq 7
check "cancel message names the control" \
  grep -Fq "agent-cancelled" "$WORK/status/checkc.out"

# ===========================================================================
# AC3/AC5: pipeline records durable status on completion
# ===========================================================================
echo "== pipeline: success records durable status"

make_fixture success "$BUDGETS_TPL"
issue_json 80
HARNESS='
set -e
printf "harness work\n" > FEATURE.md
git add FEATURE.md
git commit -qm "implement feature"
'
AGENT_SPEC_REVISION=deadbee task success 80 -- bash -c "$HARNESS" \
  > "$WORK/success/run.out" 2>&1
check "budgeted run succeeds" test $? -eq 0
check "success records phase=done in durable status" \
  sh -c 'test "$1" = "done"' sh "$(status_field success 80 phase)"
check "success records the verified PR in durable status" \
  sh -c 'test "$1" = "1"' sh "$(status_field success 80 pr)"
check "success burns exactly one attempt" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"attempts\":1"' sh "$(status_json success 80)"
check "spec revision from the dispatcher is exposed" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"spec_revision\":\"deadbee\""' sh "$(status_json success 80)"
check "success clears the last failure" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"last_failure\":\"\""' sh "$(status_json success 80)"

# ===========================================================================
# AC6: duplicate execution never double-burns attempts
# ===========================================================================
echo "== pipeline: duplicate execution"

make_fixture dup "$BUDGETS_TPL"
issue_json 81
( cd "$WORK/dup/runner" && exec bash scripts/agent-task.sh run 81 -- sleep 60 ) \
  > "$WORK/dup/run.out" 2>&1 &
DUP_PID=$!
sleep 3
task dup 81 -- true > "$WORK/dup/second.out" 2>&1
check "second worker is refused while the claim is live" test $? -eq 3
check "the refused worker burns no attempt" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"attempts\":1"' sh "$(status_json dup 81)"
kill -TERM "$DUP_PID" 2>/dev/null
wait "$DUP_PID" 2>/dev/null

# ===========================================================================
# AC2/AC6: recoverable failures count attempts; exhaustion blocks
# ===========================================================================
echo "== pipeline: recoverable failures and exhaustion"

make_fixture recover "$TWO_SHOT_BUDGETS"
issue_json 82
touch "$GH_STATE/deny-create"
task recover 82 -- true > "$WORK/recover/run1.out" 2>&1
check "first failed run exits nonzero" test $? -ne 0
check "failed run burned one attempt durably" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"attempts\":1"' sh "$(status_json recover 82)"
check "failed run recorded its last failure" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"phase\":\"failed\""' sh "$(status_json recover 82)"

task recover 82 -- true > "$WORK/recover/run2.out" 2>&1
check "second attempt is allowed while budget remains" test $? -ne 6
check "second run burned a second attempt" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"attempts\":2"' sh "$(status_json recover 82)"

: > "$GH_LOG"
task recover 82 -- true > "$WORK/recover/run3.out" 2>&1
RC3=$?
check "third dispatch is refused by the retry budget (rc 6)" test "$RC3" -eq 6
check "exhausted task holds no claim" test -z "$(claim_sha recover 82)"
check "exhausted task is marked blocked, not requeued forever" \
  sh -c 'grep -Fq -- "--add-label blocked" "$1"' sh "$GH_LOG"
check "exhausted task gets a repository-native summary comment" \
  sh -c 'grep -Fq "issue comment 82" "$1"' sh "$GH_LOG"
check "budget-exhausted outcome persisted" \
  sh -c 'grep -Fq "\"status\":\"budget_exhausted\"" "$1"' sh "$(latest_outcome recover 82)"
rm -f "$GH_STATE/deny-create"

# ===========================================================================
# AC2: between-stage checks keep resumable state
# ===========================================================================
echo "== pipeline: step and elapsed budgets"

make_fixture steps "$TIGHT_BUDGETS"
issue_json 83
: > "$GH_LOG"
task steps 83 -- bash -c 'printf w > W.md; git add W.md; git commit -qm work' \
  > "$WORK/steps/run.out" 2>&1
check "step budget exhaustion stops the run (rc 6)" test $? -eq 6
check "step exhaustion persists a budget_exhausted outcome" \
  sh -c 'grep -Fq "\"status\":\"budget_exhausted\"" "$1"' sh "$(latest_outcome steps 83)"
check "step exhaustion names the step budget" \
  sh -c 'grep -Fq "max_steps_per_run" "$1"' sh "$(latest_outcome steps 83)"
check "retry budget remaining requeues instead of blocking" \
  sh -c 'grep -Fq -- "--add-label agent-failed" "$1" && ! grep -Fq -- "--add-label blocked" "$1"' sh "$GH_LOG"
check "stopped run releases the claim" test -z "$(claim_sha steps 83)"
check "early stop keeps durable resumable state (phase + attempt burn)" \
  sh -c '( cd "$1/runner" && bash scripts/agent-budget.sh show 83 2>/dev/null ) | grep -Fq "\"phase\":\"budget_exhausted\"" && ( cd "$1/runner" && bash scripts/agent-budget.sh show 83 2>/dev/null ) | grep -Fq "\"attempts\":1"' \
  sh "$WORK/steps"

make_fixture oneshot "$ONE_SHOT_BUDGETS"
issue_json 84
: > "$GH_LOG"
task oneshot 84 -- true > "$WORK/oneshot/run.out" 2>&1
check "single-shot budget stops the run (rc 6)" test $? -eq 6
check "no retry budget left means a terminal block" \
  sh -c 'grep -Fq -- "--add-label blocked" "$1"' sh "$GH_LOG"
check "terminal block posts the summary comment" \
  sh -c 'grep -Fq "issue comment 84" "$1"' sh "$GH_LOG"
check "terminal block does not requeue as agent-failed" \
  sh -c '! grep -Fq -- "--add-label agent-failed" "$1"' sh "$GH_LOG"

make_fixture elapsed "$FAST_CLOCK_BUDGETS"
issue_json 85
task elapsed 85 -- bash -c 'printf e > E.md; git add E.md; git commit -qm work; sleep 60' \
  > "$WORK/elapsed/run.out" 2>&1
check "elapsed-time budget stops a runaway harness (rc 6)" test $? -eq 6
check "elapsed exhaustion names the time budget" \
  sh -c 'grep -Fq "max_elapsed_seconds_per_run" "$1"' sh "$(latest_outcome elapsed 85)"
check "runaway harness is killed by the watchdog" \
  sh -c 'grep -Fq "budget exhausted" "$1"' sh "$WORK/elapsed/run.out"
check "interrupted run keeps resumable state on the remote branch" \
  sh -c 'git -C "$1" show-ref --verify --quiet refs/heads/agent/issue-85' \
  sh "$WORK/elapsed/origin/origin.git"

# ===========================================================================
# AC4: pause / resume / cancel
# ===========================================================================
echo "== pipeline: pause, resume, cancel"

make_fixture controls "$BUDGETS_TPL"
issue_json 86 agent-paused
task controls 86 -- true > "$WORK/controls/paused.out" 2>&1
check "paused task is skipped before any work (rc 7)" test $? -eq 7
check "paused skip holds no claim" test -z "$(claim_sha controls 86)"
check "paused skip burns no attempt" \
  sh -c '( cd "$1/runner" && bash scripts/agent-budget.sh show 86 2>/dev/null ) | grep -Fq "\"attempts\":0"' \
  sh "$WORK/controls"
check "paused skip persists a paused outcome" \
  sh -c 'grep -Fq "\"status\":\"paused\"" "$1"' sh "$(latest_outcome controls 86)"

issue_json 86
task controls 86 -- bash -c "$HARNESS" > "$WORK/controls/resumed.out" 2>&1
check "removing the pause label resumes the task" test $? -eq 0
check "resumed task completes with durable done status" \
  sh -c 'test "$1" = "done"' sh "$(status_field controls 86 phase)"

issue_json 87 agent-cancelled
task controls 87 -- true > "$WORK/controls/cancelled.out" 2>&1
check "cancelled task is refused (rc 7)" test $? -eq 7
check "cancelled refusal persists a cancelled outcome" \
  sh -c 'grep -Fq "\"status\":\"cancelled\"" "$1"' sh "$(latest_outcome controls 87)"
check "cancelled task burns no attempt" \
  sh -c '( cd "$1/runner" && bash scripts/agent-budget.sh show 87 2>/dev/null ) | grep -Fq "\"attempts\":0"' \
  sh "$WORK/controls"

# Mid-run pause: the between-stage check must notice the label while the
# harness is in flight and stop gracefully with a comment.
issue_json 88
( cd "$WORK/controls/runner" && exec bash scripts/agent-task.sh run 88 -- sleep 8 ) \
  > "$WORK/controls/midrun.out" 2>&1 &
MID_PID=$!
sleep 2
issue_json 88 agent-paused
wait "$MID_PID" 2>/dev/null
MID_RC=$?
check "mid-run pause stops the run (rc 7)" test "$MID_RC" -eq 7
check "mid-run pause releases the claim" test -z "$(claim_sha controls 88)"
check "mid-run pause leaves a note on the issue" \
  sh -c 'grep -Fq "issue comment 88" "$1"' sh "$GH_LOG"
check "mid-run pause keeps the attempt record for the next resume" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"attempts\":1"' sh "$(status_json controls 88)"

# ===========================================================================
# AC1/AC2: repair rounds are budgeted in reconcile
# ===========================================================================
echo "== reconcile: repair rounds"

make_fixture repair "$BUDGETS_TPL"
issue_json 90
( cd "$WORK/repair/runner" && bash scripts/agent-budget.sh record 90 --field repair_rounds=+1 ) \
  >/dev/null 2>&1
( cd "$WORK/repair/runner" && AGENT_LEASE_SECONDS=1 bash scripts/agent-claim.sh acquire 90 \
    --owner crashed-worker ) >/dev/null 2>&1
sleep 2
: > "$GH_LOG"
( cd "$WORK/repair/runner" && bash scripts/agent-claim.sh reconcile ) >/dev/null 2>&1
check "reconcile succeeds with the budget engine present" test $? -eq 0
check "repair round below the cap still requeues" \
  sh -c 'grep -Fq -- "--add-label agent-failed" "$1"' sh "$GH_LOG"
check "repair requeue increments the durable repair rounds" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"repair_rounds\":2"' sh "$(status_json repair 90)"

issue_json 91
( cd "$WORK/repair/runner" && bash scripts/agent-budget.sh record 91 --field repair_rounds=+1 \
    --field repair_rounds=+1 ) >/dev/null 2>&1
( cd "$WORK/repair/runner" && AGENT_LEASE_SECONDS=1 bash scripts/agent-claim.sh acquire 91 \
    --owner crashed-worker ) >/dev/null 2>&1
sleep 2
: > "$GH_LOG"
( cd "$WORK/repair/runner" && bash scripts/agent-claim.sh reconcile ) >/dev/null 2>&1
check "repair budget exhausted blocks instead of requeueing" \
  sh -c 'grep -Fq -- "--add-label blocked" "$1" && ! grep -Fq -- "--add-label agent-failed" "$1"' sh "$GH_LOG"
check "repair budget exhaustion posts a summary comment" \
  sh -c 'grep -Fq "issue comment 91" "$1"' sh "$GH_LOG"

# ===========================================================================
# AC5: wiring and documentation
# ===========================================================================
echo "== wiring and docs"

SWEEP="$REPO_ROOT/.github/workflows/agent-sweep.yml"
check "sweep reports budget exhaustion (rc 6) distinctly" \
  grep -Fq '"$rc" -eq 6' "$SWEEP"
check "sweep reports control stops (rc 7) distinctly" \
  grep -Fq '"$rc" -eq 7' "$SWEEP"
DOCS="$REPO_ROOT/docs/BUDGETS.md"
check "budget documentation exists (docs/BUDGETS.md)" test -f "$DOCS"
check "documentation covers the cost-estimate limitation" \
  sh -c 'grep -Fqi "token" "$1"' sh "$DOCS"
check "documentation covers pause and cancel controls" \
  sh -c 'grep -Fq "agent-paused" "$1" && grep -Fq "agent-cancelled" "$1"' sh "$DOCS"
check "AGENTS.md documents the control labels" \
  sh -c 'grep -Fq "agent-paused" "$1" && grep -Fq "agent-cancelled" "$1"' sh "$REPO_ROOT/AGENTS.md"
check "no external notification channels in the budget engine" \
  sh -c '! grep -Eqi "slack|webhook|smtp|mail -s" "$1"' sh "$BUDGET"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
