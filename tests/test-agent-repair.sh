#!/usr/bin/env bash
# Acceptance tests for issue #20: automatically repair rejected PRs and
# repeat the independent review.
#
# scripts/agent-repair.sh owns the repair loop:
#   - request: a trusted review-workflow step turns a structured
#     REQUEST_CHANGES verdict artifact (or a failing CI gate with the live
#     head SHA) into a repair job for the underlying issue, recorded under
#     refs/agent-repairs/<key> and announced with the repair-requested label
#   - next/list: scheduler-side selection of issues needing repair
#   - dispatch: consumes the request (label), re-runs the shared pipeline
#     (scripts/agent-task.sh) on the EXISTING branch, so the repair runs
#     under the implementation role, pushes, and the synchronize event
#     triggers a fresh independent review bound to the new head SHA
#   - bounds: repair rounds are capped by max_repair_rounds (issue #22
#     budgets); a rejection of the SAME head after a dispatched repair (no
#     progress) or an exhausted cap moves the issue to an explicit blocked
#     state with actionable evidence
#
# Covers:
#   - AC1: rejection verdicts and failing CI evidence become repair jobs
#   - AC2: repair runs on the existing branch through the shared pipeline
#   - AC3: pushes lead to a fresh review; APPROVE never requests a repair
#   - AC4: bounded rounds, no-progress detection, blocked state + evidence
#   - AC5: label consumption dedupes repeated events; stale requests are
#     dropped without burning rounds
#   - AC6: all of the above as tests
#
# Run: bash tests/test-agent-repair.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPAIR="$REPO_ROOT/scripts/agent-repair.sh"
CLAIM="$REPO_ROOT/scripts/agent-claim.sh"
TASK="$REPO_ROOT/scripts/agent-task.sh"
BUDGET="$REPO_ROOT/scripts/agent-budget.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/adt-repair.XXXXXX")"
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

TAB="$(printf '\t')"
H1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
H2="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
H3="cccccccccccccccccccccccccccccccccccccccc"
H4="dddddddddddddddddddddddddddddddddddddddd"

if [ ! -f "$REPAIR" ]; then
  echo "FAIL - repair script exists (scripts/agent-repair.sh)"
  echo "1 test(s) failed"
  exit 1
fi
ok "repair script exists"

# --- mocked gh (fixture-driven issue/PR store with label tracking) -------------

MOCK_BIN="$WORK/mock-bin"
GH_LOG="$WORK/gh.log"
GH_STATE="$WORK/gh-state"
mkdir -p "$MOCK_BIN" "$GH_STATE/issue" "$GH_STATE/pr" "$GH_STATE/labels"
export GH_LOG GH_STATE
printf '1\n' > "$GH_STATE/next-pr"

cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
cmd="${1:-} ${2:-}"
case "$cmd" in
  "issue list")
    limit=30
    args=("$@")
    i=0
    while [ $i -lt ${#args[@]} ]; do
      [ "${args[$i]}" = "--limit" ] && limit="${args[$((i + 1))]}"
      i=$((i + 1))
    done
    [ -f "$GH_STATE/repair-queue.tsv" ] && head -n "$limit" "$GH_STATE/repair-queue.tsv"
    exit 0
    ;;
  "pr list")
    limit=30
    state=open
    args=("$@")
    i=0
    while [ $i -lt ${#args[@]} ]; do
      [ "${args[$i]}" = "--limit" ] && limit="${args[$((i + 1))]}"
      [ "${args[$i]}" = "--state" ] && state="${args[$((i + 1))]}"
      i=$((i + 1))
    done
    f="$GH_STATE/prs-$state.tsv"
    [ -f "$f" ] && head -n "$limit" "$f"
    exit 0
    ;;
  "issue view")
    n="$3"
    labels=""
    [ -f "$GH_STATE/labels/$n" ] && labels="$(cat "$GH_STATE/labels/$n")"
    ljson=""
    oldifs="$IFS"
    IFS=','
    for l in $labels; do
      [ -n "$l" ] || continue
      [ -n "$ljson" ] && ljson="$ljson,"
      ljson="$ljson{\"name\":\"$l\"}"
    done
    IFS="$oldifs"
    printf '{"number":%s,"state":"OPEN","labels":[%s]}\n' "$n" "$ljson"
    exit 0
    ;;
  "pr view")
    if [ -f "$GH_STATE/pr/$3.json" ]; then
      cat "$GH_STATE/pr/$3.json"
      exit 0
    fi
    echo "no pull request found for $3" >&2
    exit 1
    ;;
  "pr create")
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
    printf '{"number":%s,"state":"OPEN","url":"https://fixture/pr/%s","body":"%s","headRefOid":"%s"}\n' \
      "$n" "$n" "$body" "0000000000000000000000000000000000000000" > "$GH_STATE/pr/$head.json"
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
  "issue edit")
    printf '%s\n' "$*" >> "$GH_STATE/issue-edit.log"
    n=""
    add=""
    rem=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --add-label) add="$2" ;;
        --remove-label) rem="$2" ;;
        [0-9]*) [ -z "$n" ] && n="$1" ;;
      esac
      shift
    done
    f="$GH_STATE/labels/$n"
    cur=""
    [ -f "$f" ] && cur="$(cat "$f")"
    [ -z "$rem" ] || {
      new=""
      oldifs="$IFS"
      IFS=','
      for l in $cur; do
        [ "$l" = "$rem" ] && continue
        [ -n "$new" ] && new="$new,"
        new="$new$l"
      done
      IFS="$oldifs"
      cur="$new"
      printf '%s\n' "$cur" > "$f"
    }
    case ",$cur," in
      *",$add,"*) ;;
      *) [ -z "$add" ] || printf '%s%s\n' "${cur:+$cur,}" "$add" > "$f" ;;
    esac
    exit 0
    ;;
  "issue comment")
    n=""
    body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body) body="$2" ;;
        [0-9]*) [ -z "$n" ] && n="$1" ;;
      esac
      shift
    done
    printf 'issue %s comment: %s\n' "$n" "$body" >> "$GH_STATE/comments.log"
    exit 0
    ;;
esac
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"

export PATH="$MOCK_BIN:$PATH"
export GITHUB_REPOSITORY=acme/fixture

# --- fixture helpers -----------------------------------------------------------

queue_reset() { : > "$GH_STATE/repair-queue.tsv"; : > "$GH_STATE/prs-open.tsv"; }
queue_add() { # queue_add <number> <labels-csv>
  printf '%s\t%s\n' "$1" "$2" >> "$GH_STATE/repair-queue.tsv"
  printf '%s\n' "$2" > "$GH_STATE/labels/$1"
}
openpr_add() { # openpr_add <pr-number> <body>
  printf '%s\t%s\n' "$1" "$2" >> "$GH_STATE/prs-open.tsv"
}
pr_fixture() { # pr_fixture <pr> <branch> <issue> <head> [state]
  st="${5:-OPEN}"
  mkdir -p "$GH_STATE/pr/$(dirname "$2")"
  for target in "$GH_STATE/pr/$1.json" "$GH_STATE/pr/$2.json"; do
    printf '{"number":%s,"state":"%s","body":"Implement feature\\n\\nCloses #%s","headRefOid":"%s"}\n' \
      "$1" "$st" "$3" "$4" > "$target"
  done
}
pr_set_head() { # pr_set_head <pr> <head>
  for f in "$GH_STATE"/pr/"$1".json "$GH_STATE"/pr/*/"$1".json; do
    [ -f "$f" ] || continue
    sed "s/\"headRefOid\":\"[0-9a-f]*\"/\"headRefOid\":\"$2\"/" "$f" > "$f.new"
    mv "$f.new" "$f"
  done
}
labels_of() { cat "$GH_STATE/labels/$1" 2>/dev/null || printf ''; }
verdict_artifact() { # verdict_artifact <file> <pr> <verdict> <head>
  cat > "$1" <<EOF
{"schema":1,"pr":$2,"verdict":"$3","head_sha":"$4","run_id":"99","run_attempt":"1","created_at":"2026-10-09T00:00:00Z","report":"VERDICT: $3","evidence":{"dir":"/tmp","gate_digest":"deadbeef"}}
EOF
}

TWO_ROUND_BUDGETS="$WORK/budgets-two-round.json"
cat > "$TWO_ROUND_BUDGETS" <<'EOF'
{
  "max_attempts_per_issue": 3,
  "max_repair_rounds": 2,
  "max_convergence_rounds": 2,
  "max_elapsed_seconds_per_run": 10800,
  "max_steps_per_run": 8
}
EOF

make_fixture() { # make_fixture <name> [budgets-file]
  d="$WORK/$1"
  mkdir -p "$d/origin" "$d/src/scripts" "$d/src/tests" "$d/src/.agent"
  git init -q --bare "$d/origin/origin.git"
  git -C "$d/origin/origin.git" symbolic-ref HEAD refs/heads/main
  cp "$CLAIM" "$d/src/scripts/agent-claim.sh"
  cp "$TASK" "$d/src/scripts/agent-task.sh"
  cp "$BUDGET" "$d/src/scripts/agent-budget.sh"
  cp "$REPAIR" "$d/src/scripts/agent-repair.sh"
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

repair_state() { # repair_state <name> <key>
  git -C "$WORK/$1/runner" fetch -q origin "refs/agent-repairs/$2" 2>/dev/null \
    && git -C "$WORK/$1/runner" cat-file commit FETCH_HEAD | sed '1,/^$/d'
}

MARKER="$WORK/marker"

# ===========================================================================
# AC1: a REQUEST_CHANGES verdict becomes a repair job for the issue
# ===========================================================================
echo "== rejection to repair job"

queue_reset
queue_add 30 p1
openpr_add 7 'Implement feature

Closes #30'
pr_fixture 7 agent/issue-30 30 "$H1"
make_fixture rep1
verdict_artifact "$WORK/rep1-va.json" 7 REQUEST_CHANGES "$H1"

( cd "$WORK/rep1/runner" && bash scripts/agent-repair.sh request 7 --verdict-artifact "$WORK/rep1-va.json" ) \
  > "$WORK/rep1-req.out" 2>&1
check "request exits 0 for a rejected PR" test $? -eq 0
check "issue is labeled repair-requested" \
  sh -c 'printf "%s" "$1" | grep -Fq repair-requested' sh "$(labels_of 30)"
STATE="$(repair_state rep1 30)"
check "durable repair state records round 1" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"rounds\":1"' sh "$STATE"
check "durable repair state binds the rejected head" \
  sh -c 'printf "%s" "$1" | grep -Fq "$2"' sh "$STATE" "$H1"
check "durable repair state is not yet dispatched" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"dispatched\":0"' sh "$STATE"
check "repair round is synced into the budget status" \
  sh -c 'cd "$1" && bash scripts/agent-budget.sh show 30 | grep -Fq "\"repair_rounds\":1"' sh "$WORK/rep1/runner"
check "repair request is announced on the issue" \
  sh -c 'grep -Fq "issue 30 comment:" "$1" && grep -Fq "PR #7" "$1"' sh "$GH_STATE/comments.log"
check "repair request comment carries the round and trigger" \
  sh -c 'grep -Fq "Repair round 1" "$1" && grep -Fq "review" "$1"' sh "$GH_STATE/comments.log"

# APPROVE never creates a repair job (AC3: approval goes to the merge path)
queue_add 31 p1
pr_fixture 8 agent/issue-31 31 "$H1"
openpr_add 8 'Implement feature

Closes #31'
verdict_artifact "$WORK/rep1-approve.json" 8 APPROVE "$H1"
( cd "$WORK/rep1/runner" && bash scripts/agent-repair.sh request 8 --verdict-artifact "$WORK/rep1-approve.json" ) \
  > "$WORK/rep1-ap.out" 2>&1
check "request exits 0 for an approved PR (no-op)" test $? -eq 0
check "approved PR is not labeled repair-requested" \
  sh -c '! printf "%s" "$1" | grep -Fq repair-requested' sh "$(labels_of 31)"
check "approved PR records no repair state" test -z "$(repair_state rep1 31)"

# A PR that links no issue cannot enter the repair queue
pr_fixture 9 agent/issue-32 999 "$H1"
openpr_add 9 'Orphan PR with no linked issue'
( cd "$WORK/rep1/runner" && bash scripts/agent-repair.sh request 9 --head-sha "$H1" ) \
  > "$WORK/rep1-orphan.out" 2>&1
check "PR without an issue link is a clean no-op" test $? -eq 0

# Verdict artifact bound to another PR is rejected (fail closed)
verdict_artifact "$WORK/rep1-wrong.json" 999 REQUEST_CHANGES "$H1"
( cd "$WORK/rep1/runner" && bash scripts/agent-repair.sh request 7 --verdict-artifact "$WORK/rep1-wrong.json" ) \
  > "$WORK/rep1-wrong.out" 2>&1
check "verdict artifact for another PR is a usage error" test $? -eq 2

# ===========================================================================
# AC1: failing CI evidence becomes a repair job too
# ===========================================================================
echo "== failing CI gate"

queue_reset
queue_add 40 p2
openpr_add 12 'Implement feature

Closes #40'
pr_fixture 12 agent/issue-40 40 "$H2"
make_fixture rep2
( cd "$WORK/rep2/runner" && bash scripts/agent-repair.sh request 12 --head-sha "$H2" --trigger ci-gate ) \
  > "$WORK/rep2-ci.out" 2>&1
check "failing CI gate requests a repair (exit 0)" test $? -eq 0
check "CI-triggered repair labels the issue" \
  sh -c 'printf "%s" "$1" | grep -Fq repair-requested' sh "$(labels_of 40)"
STATE="$(repair_state rep2 40)"
check "CI-triggered repair records the trigger" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"trigger\":\"ci-gate\"" && printf "%s" "$1" | grep -Fq "$2"' sh "$STATE" "$H2"
check "CI-triggered repair announces the CI failure on the issue" \
  sh -c 'grep -Fq "issue 40 comment:" "$1" && grep -Fqi "ci" "$1"' sh "$GH_STATE/comments.log"

# ===========================================================================
# AC2/AC3: dispatch repairs the existing branch through the shared pipeline,
# and the repaired push leads to a fresh review (approval closes the loop)
# ===========================================================================
echo "== rejection to repair to approval"

: > "$MARKER"
FIX_HARNESS='
set -e
printf "repair ran\n" >> "$MARKER"
printf "fixes review findings\n" > FIX.md
git add FIX.md
git commit -qm "Fix review findings"
'
( cd "$WORK/rep1/runner" && MARKER="$MARKER" bash scripts/agent-repair.sh dispatch 30 --base origin/main -- bash -c "$FIX_HARNESS" ) \
  > "$WORK/rep1-dis.out" 2>&1
RC=$?
check "repair dispatch through the shared pipeline succeeds" test "$RC" -eq 0
check "repair harness ran exactly once" test "$(grep -c . "$MARKER")" -eq 1
check "repair-requested label is consumed by dispatch" \
  sh -c '! printf "%s" "$1" | grep -Fq repair-requested' sh "$(labels_of 30)"
STATE="$(repair_state rep1 30)"
check "dispatch marks the round as dispatched" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"dispatched\":1"' sh "$STATE"
check "repair pushed to the existing branch (new commit on agent/issue-30)" \
  sh -c 'test "$(git -C "$1/runner" rev-list --count origin/main..origin/agent/issue-30)" -eq 2' sh "$WORK/rep1"
check "existing PR was reused, not duplicated" \
  sh -c '! grep -Fq "pr create" "$1"' sh "$GH_LOG"
check "durable status carries the PR and a pushed repair phase" \
  sh -c 'cd "$1" && bash scripts/agent-budget.sh show 30 | grep -Fq "\"pr\":7"' sh "$WORK/rep1/runner"

# The fresh review approves the new head: no further repair round is granted.
NEW_HEAD="$(git -C "$WORK/rep1/runner" rev-parse origin/agent/issue-30)"
verdict_artifact "$WORK/rep1-approve2.json" 7 APPROVE "$NEW_HEAD"
( cd "$WORK/rep1/runner" && bash scripts/agent-repair.sh request 7 --verdict-artifact "$WORK/rep1-approve2.json" ) \
  > "$WORK/rep1-ap2.out" 2>&1
check "approval after repair stays a no-op" test $? -eq 0
STATE="$(repair_state rep1 30)"
check "approval does not grant another repair round" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"rounds\":1"' sh "$STATE"

# ===========================================================================
# AC5: duplicate events do not create duplicate repair jobs
# ===========================================================================
echo "== duplicate events"

queue_reset
queue_add 50 p1
openpr_add 20 'Implement feature

Closes #50'
pr_fixture 20 agent/issue-50 50 "$H1"
make_fixture rep3
verdict_artifact "$WORK/rep3-va.json" 20 REQUEST_CHANGES "$H1"
( cd "$WORK/rep3/runner" && bash scripts/agent-repair.sh request 20 --verdict-artifact "$WORK/rep3-va.json" ) >/dev/null 2>&1
( cd "$WORK/rep3/runner" && bash scripts/agent-repair.sh request 20 --verdict-artifact "$WORK/rep3-va.json" ) >/dev/null 2>&1
STATE="$(repair_state rep3 50)"
check "duplicate REQUEST_CHANGES events burn one round only" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"rounds\":1"' sh "$STATE"
check "duplicate events keep the request queued" \
  sh -c 'printf "%s" "$1" | grep -Fq repair-requested' sh "$(labels_of 50)"

: > "$MARKER"
NOP_HARNESS='printf "dispatched\n" >> "$MARKER"'
( cd "$WORK/rep3/runner" && MARKER="$MARKER" bash scripts/agent-repair.sh dispatch 50 --base origin/main -- bash -c "$NOP_HARNESS" ) \
  > "$WORK/rep3-dis1.out" 2>&1
check "first dispatch runs" test $? -eq 0
( cd "$WORK/rep3/runner" && MARKER="$MARKER" bash scripts/agent-repair.sh dispatch 50 --base origin/main -- bash -c "$NOP_HARNESS" ) \
  > "$WORK/rep3-dis2.out" 2>&1
check "duplicate dispatch is a clean no-op (exit 0)" test $? -eq 0
check "duplicate dispatch does not re-run the harness" test "$(grep -c . "$MARKER")" -eq 1
check "duplicate dispatch burns no extra attempt" \
  sh -c 'cd "$1" && test "$(bash scripts/agent-budget.sh show 50 | sed -n "s/.*\"attempts\":\([0-9]*\).*/\1/p")" -eq 1' sh "$WORK/rep3/runner"

# A rejection arriving while the repair claim is live (in flight) is skipped
queue_reset
queue_add 60 p1
openpr_add 30 'Implement feature

Closes #60'
pr_fixture 30 agent/issue-60 60 "$H1"
make_fixture rep4
verdict_artifact "$WORK/rep4-va.json" 30 REQUEST_CHANGES "$H1"
( cd "$WORK/rep4/runner" && bash scripts/agent-repair.sh request 30 --verdict-artifact "$WORK/rep4-va.json" ) >/dev/null 2>&1
( cd "$WORK/rep4/runner" && bash scripts/agent-claim.sh acquire 60 --owner inflight-worker --lease 3600 ) >/dev/null 2>&1
( cd "$WORK/rep4/runner" && bash scripts/agent-repair.sh dispatch 60 --base origin/main -- true ) \
  > "$WORK/rep4-dis.out" 2>&1
check "dispatch under a foreign live claim defers to the claim holder (exit 3)" test $? -eq 3
STATE="$(repair_state rep4 60)"
check "deferred dispatch still marks the round dispatched" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"dispatched\":1"' sh "$STATE"
( cd "$WORK/rep4/runner" && bash scripts/agent-repair.sh request 30 --verdict-artifact "$WORK/rep4-va.json" ) \
  > "$WORK/rep4-req2.out" 2>&1
check "rejection while the repair is in flight is skipped (exit 0)" test $? -eq 0
check "in-flight rejection does not block the issue" \
  sh -c '! printf "%s" "$1" | grep -Fq blocked' sh "$(labels_of 60)"
check "in-flight rejection burns no extra round" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"rounds\":1"' sh "$(repair_state rep4 60)"

# ===========================================================================
# AC4: repeated failures without progress move the work to blocked
# ===========================================================================
echo "== no progress"

queue_reset
queue_add 70 p1
openpr_add 40 'Implement feature

Closes #70'
pr_fixture 40 agent/issue-70 70 "$H1"
make_fixture rep5
verdict_artifact "$WORK/rep5-va.json" 40 REQUEST_CHANGES "$H1"
( cd "$WORK/rep5/runner" && bash scripts/agent-repair.sh request 40 --verdict-artifact "$WORK/rep5-va.json" ) >/dev/null 2>&1
( cd "$WORK/rep5/runner" && bash scripts/agent-repair.sh dispatch 70 --base origin/main -- true ) \
  > "$WORK/rep5-dis.out" 2>&1
check "repair round that pushes nothing still exits 0 (pipeline verifies artifacts)" test $? -eq 0
: > "$GH_STATE/comments.log"
( cd "$WORK/rep5/runner" && bash scripts/agent-repair.sh request 40 --verdict-artifact "$WORK/rep5-va.json" ) \
  > "$WORK/rep5-req2.out" 2>&1
check "re-rejection of the same head after a dispatched repair blocks (exit 6)" test $? -eq 6
check "no-progress block labels the issue blocked" \
  sh -c 'printf "%s" "$1" | grep -Fq blocked' sh "$(labels_of 70)"
check "no-progress block removes the repair request" \
  sh -c '! printf "%s" "$1" | grep -Fq repair-requested' sh "$(labels_of 70)"
check "no-progress block posts actionable evidence on the issue" \
  sh -c 'grep -Fq "issue 70 comment:" "$1" && grep -Fq "no progress" "$1" && grep -Fq "PR #40" "$1"' sh "$GH_STATE/comments.log"
check "no-progress block records the failure in durable status" \
  sh -c 'cd "$1" && bash scripts/agent-budget.sh show 70 | grep -Fq "no progress"' sh "$WORK/rep5/runner"

# ===========================================================================
# AC4: exhausted repair rounds block with evidence
# ===========================================================================
echo "== exhausted rounds"

queue_reset
queue_add 80 p1
openpr_add 50 'Implement feature

Closes #80'
pr_fixture 50 agent/issue-80 80 "$H1"
make_fixture rep6 "$TWO_ROUND_BUDGETS"
verdict_artifact "$WORK/rep6-va.json" 50 REQUEST_CHANGES "$H1"
( cd "$WORK/rep6/runner" && bash scripts/agent-repair.sh request 50 --verdict-artifact "$WORK/rep6-va.json" ) >/dev/null 2>&1
check "round 1 granted under a two-round cap" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"rounds\":1"' sh "$(repair_state rep6 80)"
pr_set_head 50 "$H2"
verdict_artifact "$WORK/rep6-va2.json" 50 REQUEST_CHANGES "$H2"
( cd "$WORK/rep6/runner" && bash scripts/agent-repair.sh request 50 --verdict-artifact "$WORK/rep6-va2.json" ) >/dev/null 2>&1
check "round 2 granted after a repaired head was rejected" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"rounds\":2" && printf "%s" "$1" | grep -Fq "$2"' sh "$(repair_state rep6 80)" "$H2"
: > "$GH_STATE/comments.log"
pr_set_head 50 "$H3"
verdict_artifact "$WORK/rep6-va3.json" 50 REQUEST_CHANGES "$H3"
( cd "$WORK/rep6/runner" && bash scripts/agent-repair.sh request 50 --verdict-artifact "$WORK/rep6-va3.json" ) \
  > "$WORK/rep6-req3.out" 2>&1
check "round 3 beyond the cap is refused (exit 6)" test $? -eq 6
check "exhausted repairs label the issue blocked" \
  sh -c 'printf "%s" "$1" | grep -Fq blocked' sh "$(labels_of 80)"
check "exhausted repairs post a summary with the cap and findings pointer" \
  sh -c 'grep -Fq "issue 80 comment:" "$1" && grep -Fq "Repair rounds" "$1" && grep -Fq "PR #50" "$1"' sh "$GH_STATE/comments.log"
check "budget counter records the exhausted cap" \
  sh -c 'cd "$1" && bash scripts/agent-budget.sh show 80 | grep -Fq "\"repair_rounds\":2"' sh "$WORK/rep6/runner"
STATE="$(repair_state rep6 80)"
check "exhausted state keeps the granted round count" \
  sh -c 'printf "%s" "$1" | grep -Fq "\"rounds\":2"' sh "$STATE"

# Once blocked by exhaustion, dispatch refuses to run the repair
( cd "$WORK/rep6/runner" && bash scripts/agent-repair.sh dispatch 80 --base origin/main -- true ) \
  > "$WORK/rep6-dis.out" 2>&1
check "dispatch after exhaustion is refused (exit 6)" test $? -eq 6

# ===========================================================================
# AC5: stale feedback is dropped without burning a repair round
# ===========================================================================
echo "== stale feedback"

queue_reset
queue_add 90 p1
openpr_add 60 'Implement feature

Closes #90'
pr_fixture 60 agent/issue-90 90 "$H1"
make_fixture rep7
verdict_artifact "$WORK/rep7-va.json" 60 REQUEST_CHANGES "$H1"
( cd "$WORK/rep7/runner" && bash scripts/agent-repair.sh request 60 --verdict-artifact "$WORK/rep7-va.json" ) >/dev/null 2>&1
: > "$MARKER"
# A newer push (e.g. a human or an overlapping worker) moved the head: the
# queued request is stale -- a fresh review already covers the new head.
pr_set_head 60 "$H2"
( cd "$WORK/rep7/runner" && MARKER="$MARKER" bash scripts/agent-repair.sh dispatch 90 --base origin/main -- bash -c 'printf "ran\n" >> "$MARKER"' ) \
  > "$WORK/rep7-dis.out" 2>&1
check "stale request dispatch is a clean no-op (exit 0)" test $? -eq 0
check "stale request does not run the repair harness" test "$(grep -c . "$MARKER")" -eq 0
check "stale request label is cleared" \
  sh -c '! printf "%s" "$1" | grep -Fq repair-requested' sh "$(labels_of 90)"
check "stale request burns no attempt" \
  sh -c 'cd "$1" && ! bash scripts/agent-budget.sh show 90 | grep -Fq "\"attempts\":1"' sh "$WORK/rep7/runner"

# A vanished PR makes the request void
queue_reset
queue_add 91 p1
openpr_add 61 'Implement feature

Closes #91'
pr_fixture 61 agent/issue-91 91 "$H1" CLOSED
make_fixture rep8
verdict_artifact "$WORK/rep8-va.json" 61 REQUEST_CHANGES "$H1"
( cd "$WORK/rep8/runner" && bash scripts/agent-repair.sh request 61 --verdict-artifact "$WORK/rep8-va.json" ) >/dev/null 2>&1
: > "$MARKER"
( cd "$WORK/rep8/runner" && MARKER="$MARKER" bash scripts/agent-repair.sh dispatch 91 --base origin/main -- bash -c 'printf "ran\n" >> "$MARKER"' ) \
  > "$WORK/rep8-dis.out" 2>&1
check "request against a closed PR dispatches nothing (exit 0)" test $? -eq 0
check "closed-PR request does not run the repair harness" test "$(grep -c . "$MARKER")" -eq 0
check "closed-PR request label is cleared" \
  sh -c '! printf "%s" "$1" | grep -Fq repair-requested' sh "$(labels_of 91)"

# ===========================================================================
# AC5: scheduler-side selection
# ===========================================================================
echo "== selection"

queue_reset
queue_add 100 'p2,repair-requested'
queue_add 101 'p1,repair-requested'
queue_add 102 'p1,repair-requested'
queue_add 103 'blocked,repair-requested'
openpr_add 70 'Closes #100'
openpr_add 71 'Closes #101'
openpr_add 72 'Closes #102'
pr_fixture 70 agent/issue-100 100 "$H1"
pr_fixture 71 agent/issue-101 101 "$H1"
pr_fixture 72 agent/issue-102 102 "$H1"
make_fixture rep9
OUT="$( cd "$WORK/rep9/runner" && bash scripts/agent-repair.sh list 2>/dev/null )"
check "repair selection orders by priority then age" \
  test "$(printf '%s\n' "$OUT" | tr '\n' ' ' | sed 's/ $//')" = "101 102 100"
check "next prints the single best repair candidate" \
  test "$( cd "$WORK/rep9/runner" && bash scripts/agent-repair.sh next 2>/dev/null )" = "101"
check "blocked issues are never selected for repair" \
  sh -c '! printf "%s" "$1" | grep -Fxq 103' sh "$OUT"

# A labeled issue without an open PR has nothing to repair: the label is
# dropped so the queue does not wedge.
queue_add 104 repair-requested
( cd "$WORK/rep9/runner" && bash scripts/agent-repair.sh next ) >/dev/null 2>&1
check "request without an open PR is voided (label dropped)" \
  sh -c '! printf "%s" "$1" | grep -Fq repair-requested' sh "$(labels_of 104)"
check "request without an open PR selects nothing extra" \
  test "$( cd "$WORK/rep9/runner" && bash scripts/agent-repair.sh list 2>/dev/null | grep -Fc .)" -eq 3

# show on unknown key fails explicitly
( cd "$WORK/rep9/runner" && bash scripts/agent-repair.sh show 999 ) >/dev/null 2>&1
check "show on a key without state exits non-zero" test $? -ne 0

# ===========================================================================
# AC3/AC5: workflow wiring
# ===========================================================================
echo "== workflow wiring"

REVIEW_YML="$REPO_ROOT/.github/workflows/pr-review.yml"
SCHED_YML="$REPO_ROOT/.github/workflows/agent-scheduler.yml"
SWEEP_YML="$REPO_ROOT/.github/workflows/agent-sweep.yml"

check "review workflow requests repair on REQUEST_CHANGES verdicts" \
  sh -c 'grep -Fq "agent-repair.sh request" "$1" && grep -Fq "verdict-artifact" "$1"' sh "$REVIEW_YML"
check "review workflow requests repair on failing CI gate" \
  sh -c 'grep -Fq "trigger ci-gate" "$1"' sh "$REVIEW_YML"
check "review gate failure no longer dead-ends the pipeline" \
  sh -c 'grep -Fq "continue-on-error: true" "$1" && grep -Fq "steps.gate.outcome == '"'"'failure'"'"'" "$1"' sh "$REVIEW_YML"
check "review steps after a failing gate are skipped" \
  sh -c 'test "$(grep -Fc "steps.gate.outcome == '"'"'success'"'"'" "$1")" -ge 4' sh "$REVIEW_YML"
check "scheduler reacts to the repair-requested label" \
  sh -c 'grep -Fq "repair-requested" "$1"' sh "$SCHED_YML"
check "scheduler dispatches repairs before new work" \
  sh -c 'grep -Fq "agent-repair.sh next" "$1" && grep -Fq "agent-repair.sh dispatch" "$1"' sh "$SCHED_YML"
check "scheduler repair dispatch runs the shared pipeline" \
  sh -c 'awk "/agent-repair.sh next/,0" "$1" | grep -Fq "agent-task.sh run"' sh "$SCHED_YML"
check "periodic sweep recovers pending repairs" \
  sh -c 'grep -Fq "agent-repair.sh list" "$1"' sh "$SWEEP_YML"
check "setup registers the repair-requested label" \
  grep -Fq "label repair-requested" "$REPO_ROOT/setup.sh"
check "AGENTS documents the repair-requested label" \
  grep -Fq "repair-requested" "$REPO_ROOT/AGENTS.md"
check "repair loop is documented" test -f "$REPO_ROOT/docs/REPAIR.md"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
