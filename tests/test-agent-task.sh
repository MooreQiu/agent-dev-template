#!/usr/bin/env bash
# Acceptance tests for issue #18 (part 2): the unified worker entry
# scripts/agent-task.sh gives every dispatch path (comment, assignment,
# scheduled sweep, repair) the same execution pipeline:
#
#   atomic claim -> isolated clean worktree from a freshly fetched target
#   branch -> harness command -> artifact verification (branch, PR, linked
#   issue, validation run) -> persisted outcome -> claim bookkeeping.
#
# Covers:
#   - prepare: isolated worktree per task on branch agent/issue-<N> from a
#     freshly fetched target branch, replacing dirty/stale worktrees
#     (AC3, dirty checkouts)
#   - prepare: resumes an existing remote branch instead of recreating work
#     (AC5, partial success)
#   - run: happy path verifies the PR and persists a succeeded outcome
#     (AC1, AC4)
#   - run: a harness that exits 0 without producing a PR is a FAILURE --
#     CLI exit status is never proof of an artifact (AC4, AC6)
#   - run: a harness that exits nonzero but left a valid PR behind (partial
#     success) is verified and succeeds idempotently without recreating the
#     PR (AC5, AC6)
#   - run: cancellation (SIGTERM) releases the claim; a hard kill leaves
#     the lease for reconcile (AC2, AC6)
#   - run: failing validation tests fail verification even with a PR (AC4)
#   - workflows route every dispatch path through the shared protocol
#     (AC1)
#
# Run: bash tests/test-agent-task.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAIM="$REPO_ROOT/scripts/agent-claim.sh"
TASK="$REPO_ROOT/scripts/agent-task.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/adt-task.XXXXXX")"
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

if [ ! -f "$TASK" ]; then
  echo "FAIL - task pipeline script exists (scripts/agent-task.sh)"
  echo "1 test(s) failed"
  exit 1
fi
ok "task pipeline script exists"

# --- mocked gh (log + fixture-driven PR store) -------------------------------

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
      # Honor --jq .body the way the real gh does (plain text, no JSON).
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

issue_json() { # issue_json <n>
  printf '{"number":%s,"title":"fixture issue %s","state":"OPEN"}\n' "$1" "$1" \
    > "$GH_STATE/issue/$1.json"
}

# --- fixture repository -------------------------------------------------------
# The origin's main branch carries the protocol scripts plus a configured
# test command, exactly like the real repository the workers check out.

make_fixture() { # make_fixture <name>
  d="$WORK/$1"
  mkdir -p "$d/origin" "$d/src/scripts" "$d/src/tests" "$d/src/.agent"
  git init -q --bare "$d/origin/origin.git"
  # Pin the bare HEAD to main regardless of the runner's init.defaultBranch
  # (CI images default to master; a dangling HEAD yields empty clones).
  git -C "$d/origin/origin.git" symbolic-ref HEAD refs/heads/main
  cp "$CLAIM" "$d/src/scripts/agent-claim.sh"
  cp "$TASK" "$d/src/scripts/agent-task.sh"
  # Budget engine rides along so the fixture pipeline matches production
  # (issue #22); defaults apply because no budgets.json is committed.
  BUDGET_SCRIPT="$REPO_ROOT/scripts/agent-budget.sh"
  [ -f "$BUDGET_SCRIPT" ] && cp "$BUDGET_SCRIPT" "$d/src/scripts/agent-budget.sh"
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

claim_sha() { # claim_sha <name> <key>
  git ls-remote "$WORK/$1/origin/origin.git" "refs/agent-claims/$2" \
    | sed -n "s/^\([0-9a-f]*\).*/\1/p"
}

task() { # task <name> <key> [args...] -- <harness command...>
  d="$WORK/$1"; shift
  key="$1"; shift
  ( cd "$d/runner" && bash "$d/runner/scripts/agent-task.sh" run "$key" "$@" )
}

worktree_of() { printf '%s/runner/.agent-work/issue-%s' "$WORK/$1" "$2"; }

# ===========================================================================
# AC3: isolated clean worktree per task, freshly fetched target branch
# ===========================================================================
echo "== prepare: isolated clean worktree"

make_fixture prep
issue_json 50
( cd "$WORK/prep/runner" && bash "$WORK/prep/runner/scripts/agent-task.sh" prepare 50 ) \
  > "$WORK/prep/prepare.out" 2>&1
check "prepare succeeds" test $? -eq 0
WT="$(worktree_of prep 50)"
check "worktree directory created outside the stale-prone checkout" test -d "$WT"
check "worktree is on the expected task branch" \
  sh -c 'test "$1" = "refs/heads/agent/issue-50"' sh "$(git -C "$WT" symbolic-ref -q HEAD)"
check "worktree is based on the freshly fetched target branch" \
  sh -c 'test "$1" = "$2"' sh "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$WORK/prep/origin/origin.git" rev-parse refs/heads/main)"
check "worktree is clean" sh -c 'test -z "$(git -C "$1" status --porcelain)"' sh "$WT"

echo "== prepare: dirty worktrees are replaced"

# Leave behind a stale, dirty worktree from an interrupted run: tracked
# modification + untracked junk + a registered worktree.
echo dirt >> "$WT/tests/test-ok.sh"
echo junk > "$WT/untracked-junk"
( cd "$WORK/prep/runner" && bash "$WORK/prep/runner/scripts/agent-task.sh" prepare 50 ) \
  > "$WORK/prep/prepare2.out" 2>&1
check "prepare over a dirty worktree succeeds" test $? -eq 0
check "dirty worktree replaced with a clean one" \
  sh -c 'test -z "$(git -C "$1" status --porcelain)"' sh "$WT"
check "untracked junk from the interrupted run is gone" test ! -e "$WT/untracked-junk"
check "replaced worktree still tracks the target branch content" \
  sh -c 'grep -Fq "echo ok" "$1"' sh "$WT/tests/test-ok.sh"

echo "== prepare: resumes an existing remote branch"

# Partial success from an earlier run: branch already pushed, no PR yet.
git -C "$WT" checkout -q -b agent/issue-51
printf 'resumed work\n' > "$WT/RESUME.md"
git -C "$WT" add RESUME.md
git -C "$WT" commit -qm "partial: work without PR"
git -C "$WT" push -q origin HEAD:refs/heads/agent/issue-51
git -C "$WT" checkout -q agent/issue-50
issue_json 51
( cd "$WORK/prep/runner" && bash "$WORK/prep/runner/scripts/agent-task.sh" prepare 51 ) \
  > "$WORK/prep/prepare3.out" 2>&1
check "prepare of a partially-succeeded issue succeeds" test $? -eq 0
WT51="$(worktree_of prep 51)"
check "existing branch is resumed, not recreated from main" \
  sh -c 'test -e "$1/RESUME.md"' sh "$WT51"
check "resumed branch points at the previously pushed work" \
  sh -c 'git -C "$1" merge-base --is-ancestor "$2" HEAD' sh "$WT51" \
    "$(git -C "$WORK/prep/origin/origin.git" rev-parse refs/heads/agent/issue-51)"

# ===========================================================================
# AC1/AC4: run -- happy path verifies artifacts and persists the outcome
# ===========================================================================
echo "== run: verified success"

make_fixture happy
issue_json 60
HARNESS='
set -e
printf "harness work\n" > FEATURE.md
git add FEATURE.md
git commit -qm "implement feature"
'
task happy 60 -- bash -c "$HARNESS" > "$WORK/happy/run.out" 2>&1
check "run with a real artifact succeeds" test $? -eq 0
check "outcome persisted in the claim registry" test -n "$(claim_sha happy 60)"
OUTCOME="$(
  ( cd "$WORK/happy/runner" && bash "$WORK/happy/runner/scripts/agent-claim.sh" status 60 2>/dev/null ) \
    | sed -n 's/.*"status":"\([^"]*\)".*/\1/p'
)"
check "claim records a succeeded outcome" test "$OUTCOME" = "succeeded"
check "outcome references the verified PR" \
  sh -c '( cd "$1" && bash scripts/agent-claim.sh status 60 2>/dev/null ) | grep -Fq "\"pr\":"' sh "$WORK/happy/runner"
check "task branch pushed to origin" \
  sh -c 'git -C "$1" show-ref --verify --quiet refs/heads/agent/issue-60' sh "$WORK/happy/origin/origin.git"
check "PR exists for the task branch" \
  test -f "$GH_STATE/pr/agent/issue-60.json"
check "PR body links the issue" \
  sh -c 'grep -Fq "Closes #60" "$1"' sh "$GH_STATE/pr/agent/issue-60.json"
check "validation artifact recorded next to the outcome" \
  sh -c 'ls "$1"/.agent/runs/task-60-*.json >/dev/null 2>&1' sh "$WORK/happy/runner"
check "PR number recorded in the persisted outcome" \
  sh -c '( cd "$1" && bash scripts/agent-claim.sh status 60 2>/dev/null ) | grep -Eq "\"pr\":[1-9][0-9]*"' sh "$WORK/happy/runner"

# Idempotent resume: a second run over the same partial state must not
# recreate the PR.
( cd "$WORK/happy/runner" && bash scripts/agent-claim.sh release 60 --force ) >/dev/null 2>&1
: > "$GH_LOG"
task happy 60 -- true > "$WORK/happy/rerun.out" 2>&1
check "rerun over an existing PR still verifies" test $? -eq 0
check "existing PR is not recreated (idempotent resume)" \
  sh -c '! grep -Fq "pr create" "$1"' sh "$GH_LOG"

# ===========================================================================
# AC4/AC6: successful CLI exit without a PR is a failure
# ===========================================================================
echo "== run: exit 0 without a PR fails"

make_fixture noprint
issue_json 61
touch "$GH_STATE/deny-create"
task noprint 61 -- true > "$WORK/noprint/run.out" 2>&1
check "exit-0 harness without a PR fails the run" test $? -ne 0
check "failed task releases the claim for retry" test -z "$(claim_sha noprint 61)"
check "failed task is requeued with agent-failed" \
  sh -c 'grep -Fq -- "--add-label agent-failed" "$1"' sh "$GH_LOG"
OUTCOME61="$(ls "$WORK/noprint/runner/.agent/runs"/task-61-*.json 2>/dev/null | tail -1)"
check "failed outcome persisted as an artifact" test -n "$OUTCOME61"
check "failed outcome names the missing PR" \
  sh -c 'grep -Eq "\"status\":\"(failed|verify_failed)\"" "$1"' sh "$OUTCOME61"
rm -f "$GH_STATE/deny-create"

# ===========================================================================
# AC4/AC5/AC6: nonzero CLI exit with a valid PR (partial success) succeeds
# ===========================================================================
echo "== run: nonzero exit with a real PR"

make_fixture partial
issue_json 62
mkdir -p "$GH_STATE/pr/agent"
printf '{"number":5,"state":"OPEN","url":"https://fixture/pr/5","body":"Closes #62 plus implementation notes"}\n' \
  > "$GH_STATE/pr/agent/issue-62.json"
HARNESS_FAIL='
printf "harness work\n" > FEATURE.md
git add FEATURE.md
git commit -qm "implement feature"
exit 1
'
task partial 62 -- bash -c "$HARNESS_FAIL" > "$WORK/partial/run.out" 2>&1
check "nonzero harness exit with a verified PR succeeds" test $? -eq 0
check "partial-success branch pushed" \
  sh -c 'git -C "$1" show-ref --verify --quiet refs/heads/agent/issue-62' sh "$WORK/partial/origin/origin.git"

# ===========================================================================
# AC4: failing validation tests fail verification
# ===========================================================================
echo "== run: failing validation"

make_fixture badtest
issue_json 63
printf '#!/bin/sh\necho broken >&2\nexit 1\n' > "$WORK/badtest/src/tests/test-broken.sh"
git -C "$WORK/badtest/src" add -A
git -C "$WORK/badtest/src" commit -qm "red: broken validation"
git -C "$WORK/badtest/src" push -q origin HEAD:refs/heads/main
( cd "$WORK/badtest/runner" && git pull -q origin main )
task badtest 63 -- bash -c 'printf x > X.md; git add X.md; git commit -qm c' \
  > "$WORK/badtest/run.out" 2>&1
check "red validation suite fails the run despite a PR" test $? -ne 0
check "validation failure requeues the task" test -z "$(claim_sha badtest 63)"

# ===========================================================================
# AC2/AC6: cancellation
# ===========================================================================
# ===========================================================================
# AC4 (review finding): a PR whose body lacks the issue link gets it
# appended without swallowing the rest of the JSON payload
# ===========================================================================
echo "== run: PR link repair"

make_fixture linkfix
issue_json 64
mkdir -p "$GH_STATE/pr/agent"
# Real gh emits --json fields sorted alphabetically: body comes first, so
# a greedy extraction used to eat number/state/url into the new body.
printf '{"body":"implementation notes without a link","number":6,"state":"OPEN","url":"https://fixture/pr/6"}\n' \
  > "$GH_STATE/pr/agent/issue-64.json"
task linkfix 64 -- bash -c 'printf y > Y.md; git add Y.md; git commit -qm c' \
  > "$WORK/linkfix/run.out" 2>&1
check "run with an unlinked PR succeeds after repair" test $? -eq 0
check "link repair edits the PR body" test -f "$GH_STATE/pr-edit-6.args"
check "repaired body keeps original text" \
  sh -c 'grep -Fq "implementation notes without a link" "$1"' sh "$GH_STATE/pr-edit-6.args"
check "repaired body links the issue" \
  sh -c 'grep -Fq "Closes #64" "$1"' sh "$GH_STATE/pr-edit-6.args"
check "repaired body does not swallow JSON fields" \
  sh -c '! grep -Fq "\"number\"" "$1"' sh "$GH_STATE/pr-edit-6.args"

# ===========================================================================
# AC2/AC6: cancellation
# ===========================================================================
echo "== run: cancellation releases the claim"

make_fixture cancel
issue_json 64
( cd "$WORK/cancel/runner" \
  && exec bash scripts/agent-task.sh run 64 -- sleep 60 ) \
  > "$WORK/cancel/run.out" 2>&1 &
TASK_PID=$!
sleep 3
kill -TERM "$TASK_PID" 2>/dev/null
wait "$TASK_PID" 2>/dev/null
CANCEL_RC=$?
check "cancelled task exits nonzero" test "$CANCEL_RC" -ne 0
check "cancelled task releases the claim" test -z "$(claim_sha cancel 64)"
check "cancellation is reported on the issue" \
  sh -c 'grep -Fq "issue comment 64" "$1"' sh "$GH_LOG"

echo "== run: hard kill leaves the lease for reconcile"

make_fixture kill9
issue_json 65
( cd "$WORK/kill9/runner" \
  && exec bash scripts/agent-task.sh run 65 -- sleep 60 ) \
  > "$WORK/kill9/run.out" 2>&1 &
TASK_PID=$!
sleep 3
kill -9 "$TASK_PID" 2>/dev/null
wait "$TASK_PID" 2>/dev/null
check "claim survives a hard kill (lease protection)" test -n "$(claim_sha kill9 65)"
check "another worker cannot acquire the abandoned claim" \
  sh -c '! ( cd "$1/runner" && bash scripts/agent-claim.sh acquire 65 --owner scavenger >/dev/null 2>&1 )' \
  sh "$WORK/kill9"

# ===========================================================================
# AC1: workflows share the single claim protocol
# ===========================================================================
echo "== workflow wiring"

SWEEP="$REPO_ROOT/.github/workflows/agent-sweep.yml"
CLAUDE="$REPO_ROOT/.github/workflows/claude.yml"

check "sweep repairs abandoned claims before dispatch" \
  grep -Fq 'agent-claim.sh reconcile' "$SWEEP"
check "sweep executes tasks through the shared pipeline" \
  grep -Fq 'agent-task.sh run' "$SWEEP"
check "sweep no longer claims by raw label edit" \
  sh -c '! grep -Fq -- "--add-label agent-claimed" "$1"' sh "$SWEEP"
check "comment dispatch executes tasks through the shared pipeline" \
  grep -Fq 'agent-task.sh run' "$CLAUDE"
check "PR-comment dispatch also uses the claim protocol" \
  grep -Eq 'agent-claim\.sh (acquire|release)' "$CLAUDE"
check "both dispatchers serialize per issue with one group prefix" \
  sh -c 'grep -Fq "agent-task-" "$1" && grep -Eq "concurrency:" "$1"' sh "$CLAUDE"
check "claim refs namespace documented in gitignore-safe location" \
  grep -Fq '.agent-work/' "$REPO_ROOT/.gitignore"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
