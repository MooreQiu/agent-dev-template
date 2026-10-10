#!/usr/bin/env bash
# Acceptance tests for issue #20: automatically repair rejected PRs and
# repeat independent review.
#
# scripts/pr-repair.sh turns a structured REQUEST_CHANGES rejection
# (PR labeled agent-failed by the review workflow) plus failing CI
# evidence into a repair job for the existing issue and PR, runs it
# through the unified pipeline (scripts/agent-task.sh) on the existing
# branch, and lets the push trigger a fresh independent review bound to
# the new head SHA.
#
# Covers:
#   - AC1: scan lists rejected PRs; dispatch collects the reviewer's
#     REQUEST_CHANGES findings and failing checks into a repair job
#   - AC2: repair runs under the implementation pipeline on the
#     existing branch (idempotent resume, scope-preserving prompt),
#     pushes fixes and publishes new validation evidence
#   - AC3: a successful repair returns the PR to review (label
#     removed, round recorded); the push triggers re-review
#   - AC4: bounded rounds (budgets integration: agent-budget.sh when
#     present, .agent/budgets.json fallback, default cap), no-progress
#     detection, exhausted work moved to an explicit blocked state
#     with actionable evidence
#   - AC5: task/PR state synchronized; duplicate events and in-flight
#     repairs deduplicated via the unified claim protocol
#   - AC6: tests for rejection-to-repair-to-approval, failing CI,
#     stale feedback, duplicate events and exhausted retries
#
# Run: bash tests/test-pr-repair.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAIM="$REPO_ROOT/scripts/agent-claim.sh"
TASK="$REPO_ROOT/scripts/agent-task.sh"
REPAIR="$REPO_ROOT/scripts/pr-repair.sh"
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

if [ ! -f "$REPAIR" ]; then
  echo "FAIL - repair orchestrator exists (scripts/pr-repair.sh)"
  echo "1 test(s) failed"
  exit 1
fi
ok "repair orchestrator exists"

# --- mocked gh (log + fixture-driven PR / issue / workflow-run store) ---------

MOCK_BIN="$WORK/mock-bin"
GH_LOG="$WORK/gh.log"
GH_STATE="$WORK/gh-state"
mkdir -p "$MOCK_BIN" "$GH_STATE/issue" "$GH_STATE/pr" "$GH_STATE/captured"
export GH_LOG GH_STATE
printf '1\n' > "$GH_STATE/next-pr"

cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
runfile_for() { # runfile_for <branch>
  printf '%s/runs-%s.json' "$GH_STATE" "$(printf '%s' "$1" | tr '/' '_')"
}
case "${1:-} ${2:-}" in
  "pr view")
    if [ -f "$GH_STATE/pr/$3.json" ]; then
      cat "$GH_STATE/pr/$3.json"
      exit 0
    fi
    echo "mock gh: no pull request $3" >&2
    exit 1
    ;;
  "pr list")
    cat "$GH_STATE/pr-list.json" 2>/dev/null || echo "[]"
    exit 0
    ;;
  "run list")
    branch=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --branch) branch="$2" ;;
      esac
      shift
    done
    f="$(runfile_for "$branch")"
    cat "${f:-[]}"
    exit 0
    ;;
  "issue view")
    cat "$GH_STATE/issue/$3.json" 2>/dev/null || echo '{"number":'"$3"',"state":"OPEN"}'
    exit 0
    ;;
  "pr edit"|"issue edit")
    exit 0
    ;;
  "pr comment")
    n="$3"
    while [ $# -gt 0 ]; do
      case "$1" in --body) printf '%s\n' "$2" >> "$GH_STATE/comment-pr-$n.log" ;; esac
      shift
    done
    exit 0
    ;;
  "issue comment")
    n="$3"
    while [ $# -gt 0 ]; do
      case "$1" in --body) printf '%s\n' "$2" >> "$GH_STATE/comment-issue-$n.log" ;; esac
      shift
    done
    exit 0
    ;;
  "pr create")
    echo "https://fixture/pr/created" >&2
    exit 1
    ;;
esac
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"

export PATH="$MOCK_BIN:$PATH"
export GITHUB_REPOSITORY=acme/fixture

# --- fixture repository -------------------------------------------------------
# Origin main carries the shared protocol scripts plus a configured test
# command, exactly like the repository workers check out. The rejected
# work lives on a pushed branch agent/issue-<N> with an open PR.

make_fixture() { # make_fixture <name>
  d="$WORK/$1"
  mkdir -p "$d/origin" "$d/src/scripts" "$d/src/tests" "$d/src/.agent"
  git init -q --bare "$d/origin/origin.git"
  git -C "$d/origin/origin.git" symbolic-ref HEAD refs/heads/main
  cp "$CLAIM" "$d/src/scripts/agent-claim.sh"
  cp "$TASK" "$d/src/scripts/agent-task.sh"
  cp "$REPAIR" "$d/src/scripts/pr-repair.sh"
  if [ -n "${FIXTURE_BUDGET_SCRIPT:-}" ] && [ -f "$FIXTURE_BUDGET_SCRIPT" ]; then
    cp "$FIXTURE_BUDGET_SCRIPT" "$d/src/scripts/agent-budget.sh"
  fi
  if [ -n "${FIXTURE_BUDGETS_JSON:-}" ] && [ -f "$FIXTURE_BUDGETS_JSON" ]; then
    cp "$FIXTURE_BUDGETS_JSON" "$d/src/.agent/budgets.json"
  fi
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

# A rejected PR scenario: original work pushed to agent/issue-<issue>,
# open PR <pr> whose live head is the reviewed-and-rejected SHA.
make_rejected_pr() { # make_rejected_pr <name> <issue> <pr>
  d="$WORK/$1"; issue="$2"; pr="$3"
  ( cd "$d/runner"
    git checkout -q -b "agent/issue-$issue"
    printf 'original work for #%s\n' "$issue" > FEATURE.md
    git add FEATURE.md
    git commit -qm "implement feature"
    git push -q origin "HEAD:refs/heads/agent/issue-$issue"
    git checkout -q main
    git branch -qD "agent/issue-$issue" )
  head="$(git -C "$d/origin/origin.git" rev-parse refs/heads/agent/issue-$issue)"
  mkdir -p "$GH_STATE/pr/agent"
  cat > "$GH_STATE/pr/$pr.json" <<EOF
{"number":$pr,"state":"OPEN","headRefOid":"$head","headRefName":"agent/issue-$issue","body":"Automated task run for #$issue. Closes #$issue","statusCheckRollup":[{"name":"CI Gate / quality-gate","conclusion":"FAILURE"},{"name":"PR Review / review","conclusion":"SUCCESS"}],"comments":[{"author":{"login":"mooreqiu-agent-dev-bot[bot]"},"body":"VERDICT: REQUEST_CHANGES - blocking issues:\\n- acceptance tests do not cover stale feedback"}]}
EOF
  cat > "$GH_STATE/pr/agent/issue-$issue.json" <<EOF
{"number":$pr,"state":"OPEN","url":"https://fixture/pr/$pr","body":"Automated task run for #$issue. Closes #$issue"}
EOF
  printf '[{"headSha":"%s","status":"completed"}]\n' "$head" \
    > "$GH_STATE/runs-agent_issue-$issue.json"
  printf '%s\n' "$head" > "$d/rejected-head"
}

pr_set() { # pr_set <pr> <field> <value>
  node -e '
    const fs = require("fs");
    const f = process.env.GH_STATE + "/pr/" + process.argv[1] + ".json";
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j[process.argv[2]] = process.argv[3];
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$1" "$2" "$3"
}

runs_set_head() { # runs_set_head <issue> <sha>
  printf '[{"headSha":"%s","status":"completed"}]\n' "$2" \
    > "$GH_STATE/runs-agent_issue-$1.json"
}

claim_sha() { # claim_sha <name> <key>
  git ls-remote "$WORK/$1/origin/origin.git" "refs/agent-claims/$2" \
    | sed -n 's/^\([0-9a-f]*\).*/\1/p'
}

repair_registry() { # repair_registry <name> <key> -> JSON or empty
  d="$WORK/$1"
  sha="$(git ls-remote "$d/origin/origin.git" "refs/agent-repairs/$2" \
    | sed -n 's/^\([0-9a-f]*\).*/\1/p')"
  [ -n "$sha" ] || return 0
  git -C "$d/runner" fetch -q origin "refs/agent-repairs/$2" 2>/dev/null
  git -C "$d/runner" cat-file commit FETCH_HEAD | sed '1,/^$/d'
}

seed_registry() { # seed_registry <name> <key> <json>
  d="$WORK/$1"
  sha="$(printf '%s\n' "$3" | \
    env GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$d/runner" commit-tree "$(git -C "$d/runner" hash-object -t tree /dev/null)")"
  git -C "$d/runner" push -q origin "$sha:refs/agent-repairs/$2"
}

jfield() { # jfield <json> <key> (single-line JSON, string fields)
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}
jnumfield() { # jnumfield <json> <key>
  printf '%s' "$1" | sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" | sed -n 1p
}

dispatch() { # dispatch <name> <pr> [extra args...] [-- <harness command...>]
  d="$WORK/$1"; shift
  ( cd "$d/runner" && bash "$d/runner/scripts/pr-repair.sh" dispatch "$@" )
}

# A harness that behaves like the implementation agent: records the job
# context (env + findings), commits a fix, and simulates the PR head
# moving when the pipeline pushes the branch.
HARNESS_FIX='
set -e
mkdir -p "$GH_STATE/captured"
env | grep "^AGENT_REPAIR_" | sort > "$GH_STATE/captured/env.txt" || true
cp "$AGENT_REPAIR_FINDINGS" "$GH_STATE/captured/findings.txt" || true
printf "fix round %s\n" "$AGENT_REPAIR_ROUND" > "FIX.md"
git add FIX.md
git commit -qm "fix review findings (round $AGENT_REPAIR_ROUND)"
node -e "
const fs = require(\"fs\"), cp = require(\"child_process\");
const f = process.env.GH_STATE + \"/pr/\" + process.env.AGENT_REPAIR_PR + \".json\";
const j = JSON.parse(fs.readFileSync(f, \"utf8\"));
j.headRefOid = cp.execSync(\"git rev-parse HEAD\").toString().trim();
fs.writeFileSync(f, JSON.stringify(j));
"
'

# ===========================================================================
# AC1: scan lists rejected PRs awaiting repair
# ===========================================================================
echo "== scan: rejected PR queue"

make_fixture scan
cat > "$GH_STATE/pr-list.json" <<'EOF'
[
  {"number": 11, "headRefName": "agent/issue-70"},
  {"number": 12, "headRefName": "agent/issue-71"},
  {"number": 13, "headRefName": "feature/human-work"}
]
EOF
SCAN_OUT="$( cd "$WORK/scan/runner" && bash scripts/pr-repair.sh scan )"
check "scan lists agent PRs labeled agent-failed" \
  sh -c 'printf "%s\n" "$1" | grep -Fxq 11 && printf "%s\n" "$1" | grep -Fxq 12' sh "$SCAN_OUT"
check "scan ignores non-agent branches" \
  sh -c '! printf "%s\n" "$1" | grep -Fxq 13' sh "$SCAN_OUT"

# ===========================================================================
# AC1/AC2/AC3: rejection -> repair -> fresh review
# ===========================================================================
echo "== dispatch: rejection to repair to review"

make_fixture core
make_rejected_pr core 70 7
H1="$(cat "$WORK/core/rejected-head")"
: > "$GH_LOG"
dispatch core 7 -- bash -c "$HARNESS_FIX" > "$WORK/core/dispatch1.out" 2>&1
DISPATCH_RC=$?
check "dispatch of a rejected PR succeeds" test "$DISPATCH_RC" -eq 0
check "repair ran through the unified pipeline on the existing branch" \
  sh -c 'grep -Fq "fix round 1" "$1/FIX.md" 2>/dev/null || git -C "$1" show HEAD:FIX.md | grep -Fq "fix round 1"' \
  sh "$WORK/core/runner/.agent-work/issue-70"
check "claim recorded a succeeded repair outcome" \
  sh -c '( cd "$1" && bash scripts/agent-claim.sh status 70 2>/dev/null ) | grep -Fq "\"status\":\"succeeded\""' \
  sh "$WORK/core/runner"
check "repair pushed new commits to the existing PR branch" \
  sh -c 'test "$(git -C "$1" rev-parse refs/heads/agent/issue-70)" != "$2"' \
  sh "$WORK/core/origin/origin.git" "$H1"
REG="$(repair_registry core 70)"
check "repair registry records the round" test "$(jnumfield "$REG" rounds)" = 1
check "repair registry binds the round to the rejected head" \
  test "$(jfield "$REG" dispatched_head)" = "$H1"
check "repair registry is not blocked" test "$(jnumfield "$REG" blocked)" = 0
check "PR re-enters review: agent-failed label removed" \
  sh -c 'grep -Fq -- "--remove-label agent-failed" "$1"' sh "$GH_LOG"
check "issue receives the repair report" \
  sh -c 'grep -Fq "issue comment 70" "$1"' sh "$GH_LOG"
check "repair report announces the fresh review" \
  sh -c 'grep -Eq "review|复审" "$1"' sh "$GH_STATE/comment-issue-70.log"
check "PR label state synchronized before new work is dispatched" \
  sh -c 'grep -Fq "pr edit 7" "$1"' sh "$GH_LOG"

# Job inputs (AC1): structured findings + failing CI evidence.
check "repair job carries the REQUEST_CHANGES findings" \
  sh -c 'grep -Fq "REQUEST_CHANGES" "$1"' sh "$GH_STATE/captured/findings.txt"
check "repair job carries the failing CI check evidence" \
  sh -c 'grep -Eq "failing|FAILURE" "$1"' sh "$GH_STATE/captured/findings.txt"
check "failing checks are named in the findings" \
  sh -c 'grep -Fq "CI Gate / quality-gate" "$1"' sh "$GH_STATE/captured/findings.txt"
check "job environment binds issue, PR, round and head" \
  sh -c 'grep -Fq "AGENT_REPAIR_ISSUE=70" "$1" && grep -Fq "AGENT_REPAIR_PR=7" "$1" && grep -Fq "AGENT_REPAIR_ROUND=1" "$1" && grep -Fq "AGENT_REPAIR_REJECTED_HEAD=" "$1"' \
  sh "$GH_STATE/captured/env.txt"

# New validation evidence (AC2): the pipeline verification recorded a
# fresh outcome artifact for the repair run.
check "new validation evidence recorded for the repair run" \
  sh -c 'ls "$1"/.agent/runs/task-70-*.json >/dev/null 2>&1' sh "$WORK/core/runner"

# A second rejection of the NEW head starts round 2 (progress made).
NEW_HEAD="$(git -C "$WORK/core/origin/origin.git" rev-parse refs/heads/agent/issue-70)"
runs_set_head 70 "$NEW_HEAD"
: > "$GH_LOG"
dispatch core 7 -- bash -c "$HARNESS_FIX" > "$WORK/core/dispatch2.out" 2>&1
check "second rejection dispatches round 2" test $? -eq 0
REG2="$(repair_registry core 70)"
check "round counter advanced" test "$(jnumfield "$REG2" rounds)" = 2

# ===========================================================================
# AC6: failing CI alone (checks failed, no reviewer report)
# ===========================================================================
echo "== dispatch: failing CI evidence only"

make_fixture fci
make_rejected_pr fci 72 8
node -e '
const fs = require("fs");
const f = process.env.GH_STATE + "/pr/8.json";
const j = JSON.parse(fs.readFileSync(f, "utf8"));
j.comments = [];
j.statusCheckRollup = [
  {"name": "CI Gate / quality-gate", "conclusion": "FAILURE"},
  {"name": "PR Review / review", "conclusion": "SUCCESS"}
];
fs.writeFileSync(f, JSON.stringify(j));
'
rm -f "$GH_STATE/captured/findings.txt"
dispatch fci 8 -- bash -c "$HARNESS_FIX" > "$WORK/fci/dispatch.out" 2>&1
check "dispatch proceeds on failing CI evidence alone" test $? -eq 0
check "failing check names reach the repair job without a report" \
  sh -c 'grep -Fq "CI Gate / quality-gate" "$1"' sh "$GH_STATE/captured/findings.txt"

# ===========================================================================
# AC6: stale feedback is not repaired
# ===========================================================================
echo "== dispatch: stale feedback"

make_fixture stale
make_rejected_pr stale 73 9
H1S="$(cat "$WORK/stale/rejected-head")"
# The PR head moved after the rejection (a repair already pushed).
git -C "$WORK/stale/runner" fetch -q origin
git -C "$WORK/stale/runner" checkout -q -b agent/issue-73 origin/agent/issue-73
printf 'already fixed\n' > "$WORK/stale/runner/FIXED.md"
git -C "$WORK/stale/runner" add FIXED.md
git -C "$WORK/stale/runner" commit -qm "already fixed elsewhere"
git -C "$WORK/stale/runner" push -q origin HEAD:refs/heads/agent/issue-73
git -C "$WORK/stale/runner" checkout -q main
H2S="$(git -C "$WORK/stale/origin/origin.git" rev-parse refs/heads/agent/issue-73)"
pr_set 9 headRefOid "$H2S"
: > "$GH_LOG"
dispatch stale 9 --rejected-head "$H1S" -- true > "$WORK/stale/dispatch.out" 2>&1
check "stale rejection (head moved) skips the repair" test $? -eq 0
check "stale skip explains itself" \
  sh -c 'grep -Fq "stale" "$1"' sh "$WORK/stale/dispatch.out"
check "stale skip dispatches nothing" \
  sh -c '! grep -Fq -- "--remove-label agent-failed" "$1"' sh "$GH_LOG"
check "stale skip burns no repair round" test -z "$(repair_registry stale 73)"

# Same detection without --rejected-head: the workflow-run history shows
# the review ran on the old head.
runs_set_head 73 "$H1S"
pr_set 9 headRefOid "$H2S"
dispatch stale 9 -- true > "$WORK/stale/dispatch2.out" 2>&1
check "sweep path also detects the stale rejection" \
  sh -c 'grep -Fq "stale" "$1"' sh "$WORK/stale/dispatch2.out"
check "sweep-path stale skip burns no round" test -z "$(repair_registry stale 73)"

# ===========================================================================
# AC5/AC6: duplicate events deduplicate via the claim protocol
# ===========================================================================
echo "== dispatch: duplicate events"

make_fixture dupe
make_rejected_pr dupe 74 10
( cd "$WORK/dupe/runner" && bash scripts/agent-claim.sh acquire 74 \
    --owner other-worker --lease 3600 ) >/dev/null 2>&1
: > "$GH_LOG"
dispatch dupe 10 -- true > "$WORK/dupe/dispatch.out" 2>&1
check "in-flight duplicate event skips" test $? -eq 0
check "duplicate skip explains itself" \
  sh -c 'grep -Fq "in flight" "$1"' sh "$WORK/dupe/dispatch.out"
check "duplicate skip burns no repair round" test -z "$(repair_registry dupe 74)"
check "duplicate skip touches no PR state" \
  sh -c '! grep -Eq "pr (edit|comment)" "$1"' sh "$GH_LOG"

# ===========================================================================
# AC4/AC6: exhausted retries move the work to an explicit blocked state
# ===========================================================================
echo "== dispatch: exhausted retries"

make_fixture exhaust
make_rejected_pr exhaust 75 11
HE="$(cat "$WORK/exhaust/rejected-head")"
r=1
while [ "$r" -le 3 ]; do
  dispatch exhaust 11 -- bash -c "
set -e
printf 'fix %s\n' '$r' > FIX.md
git add FIX.md
git commit -qm 'fix round $r'
node -e '
const fs = require(\"fs\"), cp = require(\"child_process\");
const f = process.env.GH_STATE + \"/pr/11.json\";
const j = JSON.parse(fs.readFileSync(f, \"utf8\"));
j.headRefOid = cp.execSync(\"git rev-parse HEAD\").toString().trim();
fs.writeFileSync(f, JSON.stringify(j));
'
" > "$WORK/exhaust/round$r.out" 2>&1
  check "repair round $r dispatches while within budget" test $? -eq 0
  HN="$(git -C "$WORK/exhaust/origin/origin.git" rev-parse refs/heads/agent/issue-75)"
  runs_set_head 75 "$HN"
  r=$((r + 1))
done
: > "$GH_LOG"
dispatch exhaust 11 -- true > "$WORK/exhaust/blocked.out" 2>&1
check "exhausted retries stop dispatching" test $? -eq 0
REGX="$(repair_registry exhaust 75)"
check "registry marks the work blocked" test "$(jnumfield "$REGX" blocked)" = 1
check "blocked reason mentions the exhausted budget" \
  sh -c 'printf "%s" "$1" | grep -Eq "exhaust"' sh "$REGX"
check "issue moved to the explicit blocked state" \
  sh -c 'grep -Fq "issue edit 75 --add-label blocked" "$1"' sh "$GH_LOG"
check "blocked transition releases the stale claim" \
  test -z "$(claim_sha exhaust 75)"
check "blocked transition removes the agent-claimed label" \
  sh -c 'grep -Fq -- "--remove-label agent-claimed" "$1"' sh "$GH_LOG"
check "blocked evidence is posted on the issue" \
  sh -c 'grep -Eq "blocked|exhaust" "$1"' sh "$GH_STATE/comment-issue-75.log"
check "blocked evidence is posted on the PR" \
  test -s "$GH_STATE/comment-pr-11.log"
check "blocked evidence tells humans how to resume" \
  sh -c 'grep -Fq "pr-repair.sh reset" "$1"' sh "$GH_STATE/comment-issue-75.log"
check "a repeat event does not redispatch blocked work" \
  sh -c 'grep -Fq "blocked" "$1"' sh "$WORK/exhaust/blocked.out"

# reset clears the blocked state for a human-driven retry
: > "$GH_LOG"
( cd "$WORK/exhaust/runner" && bash scripts/pr-repair.sh reset 75 ) \
  > "$WORK/exhaust/reset.out" 2>&1
check "reset clears the repair registry" test -z "$(repair_registry exhaust 75)"
check "reset removes the blocked label" \
  sh -c 'grep -Fq "issue edit 75 --remove-label blocked" "$1"' sh "$GH_LOG"

# ===========================================================================
# AC4: repeated failure without progress blocks instead of looping
# ===========================================================================
echo "== dispatch: no progress"

make_fixture noprog
make_rejected_pr noprog 76 12
HN="$(cat "$WORK/noprog/rejected-head")"
seed_registry noprog 76 \
  "{\"key\":\"76\",\"pr\":12,\"rounds\":1,\"dispatched_head\":\"$HN\",\"blocked\":0,\"blocked_reason\":\"\",\"updated_at\":1}"
( cd "$WORK/noprog/runner" && bash scripts/agent-claim.sh acquire 76 --owner w --lease 3600 ) >/dev/null 2>&1
( cd "$WORK/noprog/runner" && bash scripts/agent-claim.sh update 76 --owner w \
    --field status=succeeded --field pr=12 ) >/dev/null 2>&1
: > "$GH_LOG"
dispatch noprog 12 -- true > "$WORK/noprog/dispatch.out" 2>&1
check "verified repair without a new head blocks" test $? -eq 0
REGN="$(repair_registry noprog 76)"
check "no-progress work is marked blocked" test "$(jnumfield "$REGN" blocked)" = 1
check "no-progress reason is explicit" \
  sh -c 'printf "%s" "$1" | grep -Fq "progress"' sh "$REGN"
check "no-progress transition consumes no new round" \
  test "$(jnumfield "$REGN" rounds)" = 1
check "no-progress transition never requeues the PR for repair" \
  sh -c '! grep -Fq -- "--remove-label agent-failed" "$1"' sh "$GH_LOG"

# ===========================================================================
# AC4: budgets integration (.agent/budgets.json fallback cap)
# ===========================================================================
echo "== budgets: fallback cap from .agent/budgets.json"

FIXTURE_BUDGETS_JSON="$WORK/budgets-tight.json" make_fixture budgets
cat > "$WORK/budgets-tight.json" <<'EOF'
{
  "max_attempts_per_issue": 3,
  "max_repair_rounds": 2,
  "max_convergence_rounds": 2,
  "max_elapsed_seconds_per_run": 10800,
  "max_steps_per_run": 8
}
EOF
# rebuild: make_fixture copied the file before it was written
cp "$WORK/budgets-tight.json" "$WORK/budgets/src/.agent/budgets.json"
( cd "$WORK/budgets/src" && git add -A && git commit -qm budgets && \
  git push -q origin HEAD:refs/heads/main ) >/dev/null 2>&1
( cd "$WORK/budgets/runner" && git pull -q origin main ) >/dev/null 2>&1
make_rejected_pr budgets 77 13
seed_registry budgets 77 \
  '{"key":"77","pr":13,"rounds":2,"dispatched_head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","blocked":0,"blocked_reason":"","updated_at":1}'
dispatch budgets 13 -- true > "$WORK/budgets/dispatch.out" 2>&1
check "budgets.json repair cap is enforced" test $? -eq 0
REGB="$(repair_registry budgets 77)"
check "cap-exceeded work is blocked" test "$(jnumfield "$REGB" blocked)" = 1
check "cap reason names the configured limit" \
  sh -c 'printf "%s" "$1" | grep -Fq "max_repair_rounds"' sh "$REGB"

# An invalid budgets file fails closed: no unbounded repair dispatch.
FIXTURE_BUDGETS_JSON="$WORK/budgets-bad.json" make_fixture badbudget
cat > "$WORK/budgets-bad.json" <<'EOF'
{
  "max_repair_rounds": "many"
}
EOF
cp "$WORK/budgets-bad.json" "$WORK/badbudget/src/.agent/budgets.json"
( cd "$WORK/badbudget/src" && git add -A && git commit -qm badbudget && \
  git push -q origin HEAD:refs/heads/main ) >/dev/null 2>&1
( cd "$WORK/badbudget/runner" && git pull -q origin main ) >/dev/null 2>&1
make_rejected_pr badbudget 78 14
dispatch badbudget 14 -- true > "$WORK/badbudget/dispatch.out" 2>&1
check "invalid budgets configuration fails closed" test $? -ne 0
check "invalid budgets dispatches no harness" test -z "$(repair_registry badbudget 78)"

# ===========================================================================
# AC4: budgets integration (agent-budget.sh contract from issue #22)
# ===========================================================================
echo "== budgets: agent-budget.sh contract"

cat > "$WORK/fake-agent-budget.sh" <<'EOF'
#!/usr/bin/env bash
# Contract stand-in for scripts/agent-budget.sh (issue #22 schema).
set -u
case "$1 $2" in
  "limit max_repair_rounds")
    [ -n "${FAKE_BUDGET_MAX:-}" ] || FAKE_BUDGET_MAX=3
    printf '%s\n' "$FAKE_BUDGET_MAX"
    ;;
  "check "*)
    [ -n "${FAKE_BUDGET_CHECK_RC:-}" ] || FAKE_BUDGET_CHECK_RC=0
    printf 'budget: check rc %s\n' "$FAKE_BUDGET_CHECK_RC"
    exit "$FAKE_BUDGET_CHECK_RC"
    ;;
  "record "*)
    key="$2"
    while [ $# -gt 0 ]; do
      case "$1" in
        --field) printf '%s\n' "$2" >> "${GH_STATE:-/tmp}/budget-record-$key.log" ;;
      esac
      shift
    done
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/fake-agent-budget.sh"

FIXTURE_BUDGET_SCRIPT="$WORK/fake-agent-budget.sh" make_fixture abudget
make_rejected_pr abudget 79 15
: > "$GH_LOG"
FAKE_BUDGET_MAX=3 dispatch abudget 15 -- bash -c "$HARNESS_FIX" \
  > "$WORK/abudget/dispatch.out" 2>&1
check "dispatch with agent-budget.sh present succeeds" test $? -eq 0
check "repair round is mirrored into the budget status" \
  sh -c 'grep -Fq "repair_rounds=+1" "$1"' sh "$GH_STATE/budget-record-79.log"
check "budget record carries the PR and phase" \
  sh -c 'grep -Fq "pr=15" "$1" && grep -Fq "phase=repairing" "$1"' sh "$GH_STATE/budget-record-79.log"

# agent-budget.sh check exhaustion (rc 6) blocks the repair.
make_rejected_pr abudget 81 16
FAKE_BUDGET_CHECK_RC=6 dispatch abudget 16 -- true > "$WORK/abudget/blocked.out" 2>&1
check "budget check exhaustion blocks the repair" test $? -eq 0
check "budget-check block is explained" \
  sh -c 'grep -Eq "budget" "$1"' sh "$WORK/abudget/blocked.out"
REGC="$(repair_registry abudget 81)"
check "budget-check block moves the work to blocked" \
  test "$(jnumfield "$REGC" blocked)" = 1
check "budget-check block dispatches no harness" \
  test "$(jnumfield "$REGC" rounds)" = 0

# agent-budget.sh human control (rc 7) pauses the repair without blocking.
RH="$(node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.env.GH_STATE + "/pr/15.json", "utf8"));
  process.stdout.write(j.headRefOid);
')"
FAKE_BUDGET_CHECK_RC=7 dispatch abudget 15 --rejected-head "$RH" -- true \
  > "$WORK/abudget/paused.out" 2>&1
check "budget control pause skips the repair" test $? -eq 0
check "pause is explained as a human control" \
  sh -c 'grep -Eq "paused|control" "$1"' sh "$WORK/abudget/paused.out"
RP="$(repair_registry abudget 79)"
check "pause is not a blocked state" test "$(jnumfield "$RP" blocked)" = 0

# ===========================================================================
# AC5: closed/merged PRs and non-agent branches are never repaired
# ===========================================================================
echo "== dispatch: terminal states"

make_fixture closed
make_rejected_pr closed 80 17
pr_set 17 state MERGED
: > "$GH_LOG"
dispatch closed 17 -- true > "$WORK/closed/dispatch.out" 2>&1
check "merged PRs skip the repair" test $? -eq 0
check "merged skip dispatches nothing" \
  sh -c '! grep -Eq "pr (edit|comment)" "$1"' sh "$GH_LOG"
check "merged skip burns no round" test -z "$(repair_registry closed 80)"

make_fixture nonagent
mkdir -p "$GH_STATE/pr/agent"
cat > "$GH_STATE/pr/18.json" <<'EOF'
{"number":18,"state":"OPEN","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","headRefName":"feature/human","body":"Closes #81","statusCheckRollup":[],"comments":[]}
EOF
dispatch nonagent 18 -- true > "$WORK/nonagent/dispatch.out" 2>&1
check "non-agent branches skip the repair" test $? -eq 0
check "non-agent skip burns no round" test -z "$(repair_registry nonagent 81)"

# ===========================================================================
# AC1/AC2: workflows wire every repair path through the orchestrator
# ===========================================================================
echo "== workflow wiring"

SCHED="$REPO_ROOT/.github/workflows/agent-scheduler.yml"
SWEEP="$REPO_ROOT/.github/workflows/agent-sweep.yml"

check "scheduler reacts to the agent-failed label event" \
  sh -c 'grep -Fq "labeled" "$1" && grep -Fq "agent-failed" "$1"' sh "$SCHED"
check "scheduler repair job uses the repair orchestrator" \
  sh -c 'grep -Fq "pr-repair.sh dispatch" "$1"' sh "$SCHED"
check "scheduler passes the event head SHA for freshness binding" \
  sh -c 'grep -Fq -- "--rejected-head" "$1"' sh "$SCHED"
check "scheduler repair job runs under the implementation role env" \
  sh -c 'grep -Fq "AGENT_OWNER" "$1"' sh "$SCHED"
SCAN_LINE="$(grep -n 'pr-repair.sh scan' "$SWEEP" | head -1 | cut -d: -f1)"
QUEUE_LINE="$(grep -n 'agent-schedule.sh list' "$SWEEP" | head -1 | cut -d: -f1)"
check "sweep scans the rejected-PR queue before new work" \
  test -n "$SCAN_LINE"
check "sweep repair step runs before new queue dispatch" \
  test -n "$SCAN_LINE" -a -n "$QUEUE_LINE" -a "$SCAN_LINE" -lt "$QUEUE_LINE"
check "sweep dispatches repairs through the orchestrator" \
  sh -c 'grep -Fq "pr-repair.sh dispatch" "$1"' sh "$SWEEP"

# Scope preservation (AC2): the default repair harness prompt must tell
# the implementer to fix only the review findings.
check "default repair prompt preserves the approved scope" \
  sh -c 'grep -Eq "范围|scope" "$1" && grep -Fq "AGENT_REPAIR_FINDINGS" "$1"' sh "$REPAIR"
check "default repair prompt treats findings as untrusted input" \
  sh -c 'grep -Eq "不可信|untrusted" "$1"' sh "$REPAIR"
check "default repair prompt runs TDD for the fixes" \
  sh -c 'grep -Eq "TDD|失败测试" "$1"' sh "$REPAIR"
check "default repair prompt announces the automatic re-review" \
  sh -c 'grep -Eq "复审|re-?review" "$1"' sh "$REPAIR"
check "repair artifacts are ignored by git" \
  grep -Fq '.agent/repair/' "$REPO_ROOT/.gitignore"

# ===========================================================================
# issue #75: dispatch failures must be diagnosable, not swallowed
# ===========================================================================
echo "== dispatch: diagnosable failures (issue #75)"

# The first real repair run (agent-sweep run 37972083041) died with
# "cannot resolve PR" and no reason: the gh stderr was discarded, so the
# actual outage (token, API, or a bad queue entry) was invisible -- and
# the sweep job still reported success. Failures on the queue -> dispatch
# path must stay loud end to end.

# gh's own error text must reach the repair error message.
make_fixture loud
make_rejected_pr loud 82 19
dispatch loud 404 -- true > "$WORK/loud/unresolved.out" 2>&1
check "an unresolvable PR fails the dispatch" test $? -ne 0
check "the gh failure reason reaches the repair error message" \
  sh -c 'grep -Fq "no pull request 404" "$1"' sh "$WORK/loud/unresolved.out"

# scan output is dispatch input: only bare numbers may pass, anything
# else is skipped with a logged reason instead of failing `gh pr view`.
make_fixture sanitize
cat > "$GH_STATE/pr-list.json" <<'EOF'
[
  {"number": 21, "headRefName": "agent/issue-90"},
  {"number": 1.5, "headRefName": "agent/issue-91"},
  {"number": 22, "headRefName": "feature/human"}
]
EOF
SCAN_RAW="$( cd "$WORK/sanitize/runner" && bash scripts/pr-repair.sh scan 2>"$WORK/sanitize/scan.err" )"
check "scan emits only bare numbers" \
  sh -c 'printf "%s\n" "$1" | grep -Fxq 21' sh "$SCAN_RAW"
check "scan drops non-numeric queue entries" \
  sh -c '! printf "%s\n" "$1" | grep -Fq "1.5"' sh "$SCAN_RAW"
check "scan logs why a queue entry was skipped" \
  sh -c 'grep -Fq "1.5" "$1"' sh "$WORK/sanitize/scan.err"

# The sweep loop must re-validate dispatch input and must not swallow a
# failed dispatch: the job has to end non-zero so monitoring can page.
check "sweep re-validates scan entries as bare numbers before dispatch" \
  grep -Fq 'non-numeric entry' "$SWEEP"
check "a failed repair dispatch fails the sweep job" \
  grep -Fq 'REPAIR_FAILED=1' "$SWEEP"
check "the sweep failure is announced as an error annotation" \
  sh -c 'grep -Fq "::error::" "$1" && grep -Fq "repair dispatch failed" "$1"' sh "$SWEEP"

# ===========================================================================
# issue #78: the scheduler's immediate-repair path must not swallow
# dispatch failures either
# ===========================================================================
echo "== scheduler: immediate-repair failures are loud (issue #78)"

# issue #75 made the sweep loud, but the scheduler's labeled-event repair
# job kept the same `|| rc=$?` swallow: its case only echoed the failure,
# so the job stayed green and nothing paged. The immediate path is a
# rejected PR's first repair chance, so a failed dispatch must end that
# job non-zero right after the failure is logged (the daily sweep still
# retries as the fallback). The checks scope to the run body after the
# dispatch line because the workflow already uses `exit 1` and
# `::error::` for unrelated input validation.
REPAIR_STEP="$WORK/sched-repair-step.sh"
awk '
  /^      - name: Repair rejected PR/ { step = 1; next }
  step && /^        run: \|/ { inrun = 1; next }
  inrun && NF && !/^          / { exit }
  inrun { print substr($0, 11) }
' "$SCHED" > "$REPAIR_STEP"
DISPATCH_LINE="$(grep -n 'pr-repair.sh dispatch' "$REPAIR_STEP" | head -1 | cut -d: -f1)"
check "the scheduler repair step dispatches before its failure handling" \
  test -n "$DISPATCH_LINE"
FAIL_TAIL="$(tail -n "+$DISPATCH_LINE" "$REPAIR_STEP")"
check "a failed immediate repair dispatch fails the scheduler job" \
  sh -c 'printf "%s" "$1" | grep -Fq "exit 1"' sh "$FAIL_TAIL"
check "the immediate repair failure is announced as an error annotation" \
  sh -c 'printf "%s" "$1" | grep -Fq "::error::repair dispatch failed"' sh "$FAIL_TAIL"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
