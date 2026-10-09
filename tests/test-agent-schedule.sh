#!/usr/bin/env bash
# Acceptance tests for issue #17: the scheduler decides WHAT to work on
# next. scripts/agent-schedule.sh inspects the complete ready-for-agent
# queue (not just the default API page), honors p0-p3 ordering with the
# documented p0 blocking semantics, resolves dependency metadata, and
# only selects tasks whose prerequisites have been successfully MERGED
# (an issue merely marked complete by an agent does not count). The
# event-driven dispatch (.github/workflows/agent-scheduler.yml) advances
# the queue after each merge and on newly available work, one task per
# event (serial baseline); the periodic sweep stays as the recovery path
# and now selects through the same scheduler.
#
# Covers:
#   - drained queue: no eligible task prints nothing and exits 0 (AC6)
#   - dependency chains resolve in merge order, link by link (AC1, AC6)
#   - a dependency closed without a merged PR does not satisfy (AC1)
#   - substring dependency refs do not false-positive (#711 vs #71) (AC1)
#   - merged work is not duplicated even while its issue record lags (AC5)
#   - p0-p3 ordering and unlabeled fallback (AC2)
#   - p0 blocking semantics: any p0 in the queue holds all other work,
#     including when the p0 itself is dependency-blocked (AC2)
#   - the complete queue is inspected beyond the default API page (AC2)
#   - blocked/claimed/assigned issues are never selected (AC2, AC5)
#   - issues with an open PR in review are not re-selected (AC5)
#   - duplicate events pick the same task; the claim protocol dedupes
#     the second dispatch (AC3, AC6)
#   - workflows wire selection through the scheduler (AC3, AC4)
#
# Run: bash tests/test-agent-schedule.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHED="$REPO_ROOT/scripts/agent-schedule.sh"
CLAIM="$REPO_ROOT/scripts/agent-claim.sh"
TASK="$REPO_ROOT/scripts/agent-task.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/adt-sched.XXXXXX")"
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

if [ ! -f "$SCHED" ]; then
  echo "FAIL - scheduler script exists (scripts/agent-schedule.sh)"
  echo "1 test(s) failed"
  exit 1
fi
ok "scheduler script exists"

# --- mocked gh (fixture-driven queue and PR store) ----------------------------

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
  "issue list")
    # Honor --limit exactly like the real gh (default page: 30 results).
    limit=30
    args=("$@")
    i=0
    while [ $i -lt ${#args[@]} ]; do
      [ "${args[$i]}" = "--limit" ] && limit="${args[$((i + 1))]}"
      i=$((i + 1))
    done
    [ -f "$GH_STATE/queue.tsv" ] && head -n "$limit" "$GH_STATE/queue.tsv"
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

# --- fixture helpers -----------------------------------------------------------

queue_reset() { : > "$GH_STATE/queue.tsv"; : > "$GH_STATE/prs-merged.tsv"; : > "$GH_STATE/prs-open.tsv"; }
queue_add() { # queue_add <number> <labels-csv> <assignee-count> <body-with-\n-escapes>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$GH_STATE/queue.tsv"
}
queue_rm() { # queue_rm <number>
  grep -v "^$1$TAB" "$GH_STATE/queue.tsv" > "$GH_STATE/queue.tsv.new"
  mv "$GH_STATE/queue.tsv.new" "$GH_STATE/queue.tsv"
}
merged_add() { # merged_add <pr-number> <body> -- registers a MERGED pull request
  printf '%s\t%s\n' "$1" "$2" >> "$GH_STATE/prs-merged.tsv"
}
openpr_add() { # openpr_add <pr-number> <body> -- registers an OPEN pull request
  printf '%s\t%s\n' "$1" "$2" >> "$GH_STATE/prs-open.tsv"
}
issue_json() { # issue_json <n>
  printf '{"number":%s,"title":"fixture issue %s","state":"OPEN"}\n' "$1" "$1" \
    > "$GH_STATE/issue/$1.json"
}

sched() { # sched <args...> -- run the scheduler with mocked gh
  ( cd "$WORK" && bash "$SCHED" "$@" )
}
sched_next() { sched next 2>/dev/null; }
sched_list() { sched list "$@" 2>/dev/null; }

# ===========================================================================
# AC6: a fully drained queue
# ===========================================================================
echo "== drained queue"

queue_reset
OUT="$(sched_next)"; RC=$?
check "drained queue: next prints nothing" test -z "$OUT"
check "drained queue: next exits 0" test "$RC" -eq 0
OUT="$(sched_list)"; RC=$?
check "drained queue: list prints nothing" test -z "$OUT"
check "drained queue: list exits 0" test "$RC" -eq 0
check "queue query targets the ready-for-agent label with a large page" \
  sh -c 'grep -Fq -- "--label ready-for-agent" "$1" && grep -Fq -- "--state open" "$1" && grep -Eq -- "--limit (1000|[1-9][0-9]{3,})" "$1"' sh "$GH_LOG"

# ===========================================================================
# AC1/AC6: dependency chains resolve in merge order
# ===========================================================================
echo "== dependency chain"

queue_reset
queue_add 10 ready-for-agent 0 'task A'
queue_add 11 ready-for-agent 0 'task B\n\n## Dependencies\nDepends: #10\n'
queue_add 12 ready-for-agent 0 'task C\n\n## Dependencies\n#11, #10\n'
check "chain head is the only eligible task" test "$(sched_next)" = "10"
check "dependents stay out of the batch until merged" test "$(sched_list)" = "10"

# Task A merges: its PR landed and the issue closed. B unlocks, C still
# waits on B.
merged_add 5 'Implement A\n\nCloses #10'
queue_rm 10
check "merged dependency unlocks the direct dependent" test "$(sched_next)" = "11"
check "transitive dependent stays blocked" test "$(sched_list)" = "11"

merged_add 6 'Implement B\n\nCloses #11'
queue_rm 11
check "second merge unlocks the transitive dependent" test "$(sched_next)" = "12"

# ===========================================================================
# AC1: closed-without-merge does not satisfy a dependency
# ===========================================================================
echo "== completion without merge"

queue_reset
queue_add 21 ready-for-agent 0 'task\n\n## Dependencies\n#20, #19\n'
check "closed-but-unmerged dependency keeps the task blocked" test -z "$(sched_next)"

queue_add 20 ready-for-agent 0 'dependency issue itself open'
check "open unmerged dependency blocks only its dependent, not itself" \
  test "$(sched_next)" = "20"

# ===========================================================================
# AC1: substring dependency refs must not false-positive
# ===========================================================================
echo "== substring refs"

queue_reset
queue_add 72 ready-for-agent 0 'task\n\n## Dependencies\nDepends: #71\n'
merged_add 9 'Closes #711'
check "PR linking #711 does not satisfy dependency #71" test -z "$(sched_next)"
merged_add 10 'Fixes #71'
check "PR linking #71 exactly does satisfy it" test "$(sched_next)" = "72"

# ===========================================================================
# AC5: merged work is not duplicated
# ===========================================================================
echo "== merged work not duplicated"

queue_reset
# Issue #30's issue record lags open, but its work is merged: it must not
# be scheduled again, while dependents become eligible.
queue_add 30 ready-for-agent 0 'merged task whose issue stayed open'
queue_add 31 ready-for-agent 0 'dependent\n\n## Dependencies\nDepends: #30\n'
merged_add 11 'Closes #30'
check "already-merged task is not rescheduled" test "$(sched_next)" = "31"

# ===========================================================================
# AC2: priority ordering
# ===========================================================================
echo "== priority ordering"

queue_reset
queue_add 40 ready-for-agent,p2 0 'p2 task'
queue_add 41 ready-for-agent,p1 0 'p1 task'
queue_add 42 ready-for-agent 0 'unlabeled task'
queue_add 43 ready-for-agent,p3 0 'p3 task'
check "selection order is p1, p2, p3, unlabeled" \
  test "$(sched_list | tr '\n' ' ' | sed 's/ $//')" = "41 40 43 42"

# ===========================================================================
# AC2: p0 blocking semantics
# ===========================================================================
echo "== p0 blocking"

queue_reset
# A dependency-blocked p0 still holds the whole queue: nothing runs.
queue_add 50 ready-for-agent,p0 0 'p0 waiting on a merge\n\n## Dependencies\nDepends: #55\n'
queue_add 52 ready-for-agent,p1 0 'p1 ready'
check "dep-blocked p0 holds all lower-priority work" test -z "$(sched_next)"

queue_reset
queue_add 53 ready-for-agent,p0 0 'p0 ready'
queue_add 54 ready-for-agent,p1 0 'p1 ready'
check "only p0 work is schedulable while a p0 is queued" test "$(sched_list)" = "53"

# ===========================================================================
# AC2: the complete queue is inspected, not the default API page
# ===========================================================================
echo "== large queue"

queue_reset
i=1
while [ $i -le 45 ]; do
  queue_add $((100 + i)) ready-for-agent,p3 0 "bulk task $i"
  i=$((i + 1))
done
COUNT="$(sched_list | grep -c .)"
check "tasks beyond the default 30-result page are scheduled" test "$COUNT" -eq 45

# ===========================================================================
# AC2/AC5: blocked, claimed and assigned issues are never selected
# ===========================================================================
echo "== exclusion filters"

queue_reset
queue_add 60 ready-for-agent,blocked 0 'blocked label'
queue_add 61 ready-for-agent,agent-claimed 0 'claim held'
queue_add 62 ready-for-agent 1 'has an assignee'
check "blocked/claimed/assigned issues are all excluded" test -z "$(sched_next)"

# ===========================================================================
# AC5: an open PR in review is not re-selected
# ===========================================================================
echo "== open PR reconciliation"

queue_reset
queue_add 63 ready-for-agent 0 'task with a PR under review'
queue_add 64 ready-for-agent 0 'fresh task'
openpr_add 20 'Implement 63\n\nCloses #63'
check "task with an open PR waits for review" test "$(sched_next)" = "64"

# ===========================================================================
# AC3/AC6: duplicate events are deduped by the claim protocol
# ===========================================================================
echo "== duplicate events"

make_fixture() { # make_fixture <name>
  d="$WORK/$1"
  mkdir -p "$d/origin" "$d/src/scripts" "$d/src/tests" "$d/src/.agent"
  git init -q --bare "$d/origin/origin.git"
  git -C "$d/origin/origin.git" symbolic-ref HEAD refs/heads/main
  cp "$CLAIM" "$d/src/scripts/agent-claim.sh"
  cp "$TASK" "$d/src/scripts/agent-task.sh"
  cp "$SCHED" "$d/src/scripts/agent-schedule.sh"
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
  git -C "$d/src" init -q
  git -C "$d/src" add -A
  git -C "$d/src" commit -qm "baseline"
  git -C "$d/src" remote add origin "$d/origin/origin.git"
  git -C "$d/src" push -q origin HEAD:refs/heads/main
  git clone -q "$d/origin/origin.git" "$d/runner"
  git -C "$d/runner" config user.name runner
  git -C "$d/runner" config user.email runner@example.com
}

queue_reset
queue_add 70 ready-for-agent 0 'next up'
issue_json 70
make_fixture dup

FIRST="$( cd "$WORK/dup/runner" && bash scripts/agent-schedule.sh next 2>/dev/null )"
SECOND="$( cd "$WORK/dup/runner" && bash scripts/agent-schedule.sh next 2>/dev/null )"
check "duplicate events select the same task" test "$FIRST" = "70" -a "$SECOND" = "70"

HARNESS='
set -e
printf "harness work\n" > FEATURE.md
git add FEATURE.md
git commit -qm "implement feature"
'
( cd "$WORK/dup/runner" && bash scripts/agent-task.sh run 70 -- bash -c "$HARNESS" ) \
  > "$WORK/dup/run1.out" 2>&1
check "first event's dispatch succeeds" test $? -eq 0
( cd "$WORK/dup/runner" && bash scripts/agent-task.sh run 70 -- true ) \
  > "$WORK/dup/run2.out" 2>&1
check "duplicate event's dispatch is denied by the held claim (exit 3)" test $? -eq 3

# ===========================================================================
# AC3/AC4: workflow wiring
# ===========================================================================
echo "== workflow wiring"

SCHEDULER_YML="$REPO_ROOT/.github/workflows/agent-scheduler.yml"
SWEEP_YML="$REPO_ROOT/.github/workflows/agent-sweep.yml"

check "event-driven scheduler workflow exists" test -f "$SCHEDULER_YML"
check "scheduler advances after PR merges" \
  sh -c 'grep -Fq "types: [closed]" "$1" && grep -Fq "merged == true" "$1"' sh "$SCHEDULER_YML"
check "scheduler reacts to newly available work" \
  sh -c 'grep -Fq "ready-for-agent" "$1"' sh "$SCHEDULER_YML"
check "scheduler selects through the dependency-aware selector" \
  grep -Fq 'agent-schedule.sh next' "$SCHEDULER_YML"
check "scheduler dispatches through the shared pipeline" \
  grep -Fq 'agent-task.sh run' "$SCHEDULER_YML"
check "scheduler repairs claims before selecting" \
  grep -Fq 'agent-claim.sh reconcile' "$SCHEDULER_YML"
check "scheduler runs are serialized (serial baseline)" \
  sh -c 'grep -Fq "agent-scheduler" "$1" && grep -Eq "cancel-in-progress: false" "$1"' sh "$SCHEDULER_YML"
check "scheduler fetches the latest target branch per task" \
  grep -Fq -- '--target "origin/$BASE"' "$SCHEDULER_YML"
check "periodic sweep selects through the scheduler" \
  grep -Fq 'agent-schedule.sh list' "$SWEEP_YML"
# Pattern passed as an argument so no shell layer ever substitutes the
# literal "$(gh issue list" text.
SWEEP_RAW_SEL='QUEUED=$(gh issue list'
check "periodic sweep no longer selects from the default issue page" \
  sh -c '! grep -Fq "$2" "$1"' sh "$SWEEP_YML" "$SWEEP_RAW_SEL"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
