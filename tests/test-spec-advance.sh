#!/usr/bin/env bash
# Acceptance tests for issue #47: automatically advance approved features
# between pipeline stages.
#
# Covers (issue #47 acceptance criteria):
#   AC1 an explicit human approval/start action durably identifies the
#      feature and approved revision and advances planning and issue
#      generation without further routine human triggers (after-start
#      hands off to the scheduler)
#   AC2 after the feature queue drains, convergence is invoked; remediation
#      returns to the same scheduler; verified merge/recovery scheduling
#      stays event-driven
#   AC3 automation-generated transitions are authenticated so they actually
#      trigger downstream workflows (workflow_dispatch with the workflow
#      token, asserted at the gh boundary -- no model prompts involved)
#   AC4 idempotent stage/run keys prevent duplicate jobs from repeated or
#      reordered events (in-flight convergence run key, terminal complete)
#   AC5 pause, cancellation, genuine blockers, and project-wide budgets are
#      respected at each transition; blocked is a documented resumable state
#   AC6 repository-native stage summaries with next action and evidence;
#      transition tests for duplicate events, drained queue, remediation,
#      and exhausted/invalid budget
#
# Run: bash tests/test-spec-advance.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-spec-advance.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

GH_LOG="$TMP/gh.log"
DISPATCH_LOG="$TMP/dispatch.log"
TOKEN_LOG="$TMP/token.log"
MOCK_BIN="$TMP/bin"
ISSUES_TSV="$TMP/issues.tsv"    # gh issue list --state all (closed + open)
OPEN_TSV="$TMP/open.tsv"        # gh issue list --milestone <f> --state open
                                #   (drain gate: blocked rows already exempted)
LABELS_TSV="$TMP/labels.tsv"    # gh issue list --milestone <f> open (pause scan)
MS_STATE="$TMP/ms-state"        # milestone state for the fixture features
RUNS_TSV="$TMP/runs.tsv"        # gh run list --workflow spec-converge.yml
DISPATCH_RC="$TMP/dispatch-rc"  # exit code of gh workflow run
BUDGET_FILE="$TMP/budgets.json"
SUMMARY_FILE="$TMP/summary.md"
mkdir -p "$MOCK_BIN"
: > "$ISSUES_TSV"
: > "$OPEN_TSV"
: > "$LABELS_TSV"
: > "$RUNS_TSV"
printf 'open\n' > "$MS_STATE"
printf '0\n' > "$DISPATCH_RC"
printf '{"max_attempts_per_issue": 3, "max_repair_rounds": 3, "max_convergence_rounds": 3}\n' > "$BUDGET_FILE"

failures=0
ok()   { echo "ok - $1"; }
bad()  { echo "FAIL - $1"; failures=$((failures + 1)); }

check() { # check <description> <command...>
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# --- mocked gh (records every call; serves fixture state) -------------------
cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
if [ "$1" = repo ] && [ "$2" = view ]; then echo "acme/fixture"; exit 0; fi
if [ "$1" = workflow ] && [ "$2" = run ]; then
  printf 'workflow-run %s\n' "$*" >> "$DISPATCH_LOG"
  printf 'GH_TOKEN=%s\n' "${GH_TOKEN:-}" >> "$TOKEN_LOG"
  printf 'GITHUB_TOKEN=%s\n' "${GITHUB_TOKEN:-}" >> "$TOKEN_LOG"
  rc=$(cat "$DISPATCH_RC" 2>/dev/null); case "$rc" in ''|*[!0-9]*) rc=0 ;; esac
  exit "$rc"
fi
if [ "$1" = run ] && [ "$2" = list ]; then cat "$RUNS_TSV"; exit 0; fi
if [ "$1" = issue ] && [ "$2" = list ]; then
  for a in "$@"; do
    if [ "$a" = "--milestone" ]; then
      # Two consumers query the open milestone queue: the convergence drain
      # gate (blocked rows already exempted by its --jq) and the pause/cancel
      # label scan (raw label names).
      for b in "$@"; do
        if printf '%s' "$b" | grep -q 'join'; then cat "$LABELS_TSV"; exit 0; fi
      done
      cat "$OPEN_TSV"; exit 0
    fi
  done
  cat "$ISSUES_TSV"; exit 0
fi
if [ "$1" = api ]; then
  for a in "$@"; do
    if [ "$a" = "-X" ]; then exit 0; fi # mutation recorded above only
  done
  if printf '%s' "$*" | grep -q 'actions/artifacts'; then echo '[]'; exit 0; fi
  cat "$MS_STATE"; exit 0
fi
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"
export GH_LOG DISPATCH_LOG TOKEN_LOG ISSUES_TSV OPEN_TSV LABELS_TSV MS_STATE RUNS_TSV DISPATCH_RC

FEATURE="016-demo"
FEATURE_B="017-other"

# --- fixture repository with approved features --------------------------------
make_fixture() { # make_fixture <dir>
  fx=$1
  mkdir -p "$fx/scripts" "$fx/specs/$FEATURE" "$fx/specs/$FEATURE_B" "$fx/specs/018-noapp"
  for s in spec-advance.sh spec-converge.sh spec-converge-precheck.sh agent-budget.sh; do
    cp "$REPO_ROOT/scripts/$s" "$fx/scripts/$s" 2>/dev/null
  done
  git -C "$fx" init -q
  cat > "$fx/specs/$FEATURE/spec.md" <<EOSPEC
# Spec: $FEATURE

## Requirements
- REQ1 The feature works end to end.
- REQ2 Export produces a signed artifact.
- REQ3 Reports are auditable.
EOSPEC
  cp "$fx/specs/$FEATURE/spec.md" "$fx/specs/$FEATURE_B/spec.md"
  cp "$fx/specs/$FEATURE/spec.md" "$fx/specs/018-noapp/spec.md"
  git -C "$fx" add -A
  git -C "$fx" -c user.name=Test -c user.email=test@example.com commit -qm "spec"
  R1=$(git -C "$fx" rev-parse HEAD)
  printf '%s\n' "$R1" > "$fx/.approved"
  cat > "$fx/specs/$FEATURE/approval.json" <<EOAPP
{
  "spec": "specs/$FEATURE/spec.md",
  "revision": "$R1",
  "approved_by": "tester",
  "approved_at": "2026-10-09T00:00:00Z"
}
EOAPP
  sed "s#specs/$FEATURE/#specs/$FEATURE_B/#" \
    "$fx/specs/$FEATURE/approval.json" > "$fx/specs/$FEATURE_B/approval.json"
  printf '# Plan: %s\nApproach derived from the approved spec.\n' "$FEATURE" \
    > "$fx/specs/$FEATURE/plan.md"
  cat > "$fx/specs/$FEATURE/tasks.md" <<'EOTASK'
# Tasks: 016-demo

## Phase 1
- [x] T001 Create project structure per implementation plan
- [x] T002 Implement service in src/services/ (depends on T001)
EOTASK
  # specs/018-noapp intentionally has no approval.json: the entrypoint gate
  # must reject it (no discovery here either -- discovery keys on the record).
  git -C "$fx" add -A
  git -C "$fx" -c user.name=Test -c user.email=test@example.com commit -qm "artifacts"
}

FX="$TMP/repo"
make_fixture "$FX"
SA="$FX/scripts/spec-advance.sh"
R1=$(cat "$FX/.approved")

OUT_ERR="$TMP/err.txt"
OUT_FILE="$TMP/out.txt"

run_sa() { # run_sa [args...] -> $STATUS / $OUT_FILE / $OUT_ERR
  : > "$GH_LOG"
  : > "$DISPATCH_LOG"
  : > "$TOKEN_LOG"
  : > "$SUMMARY_FILE"
  OUT=$(cd "$FX" && PATH="$MOCK_BIN:$PATH" GITHUB_TOKEN=workflow-token-dummy \
    GH_TOKEN=app-token-dummy AGENT_BUDGET_FILE="$BUDGET_FILE" \
    GITHUB_STEP_SUMMARY="$SUMMARY_FILE" bash "$SA" "$@" 2>"$OUT_ERR")
  STATUS=$?
  printf '%s\n' "$OUT" > "$OUT_FILE"
}

# Drained-by-default fixture state between scenarios.
reset_state() {
  : > "$ISSUES_TSV"
  : > "$OPEN_TSV"
  : > "$LABELS_TSV"
  : > "$RUNS_TSV"
  printf 'open\n' > "$MS_STATE"
  printf '0\n' > "$DISPATCH_RC"
  printf '{"max_attempts_per_issue": 3, "max_repair_rounds": 3, "max_convergence_rounds": 3}\n' > "$BUDGET_FILE"
}

dispatch_count() { wc -l < "$DISPATCH_LOG" | tr -d ' '; }

# ============================================================================
echo "== usage and argument gates =="

run_sa
check "no arguments prints usage and exits 2" \
  sh -c '[ "$1" = 2 ] && grep -q "Usage" "$2"' sh "$STATUS" "$OUT_ERR"
run_sa bogus-command
check "unknown command exits 2" sh -c '[ "$1" = 2 ]' sh "$STATUS"
run_sa after-start "specs/$FEATURE/spec.md"
check "after-start without a revision is a usage error" \
  sh -c '[ "$1" = 2 ]' sh "$STATUS"
run_sa after-converge "specs/$FEATURE/spec.md" "$R1"
check "after-converge without --verify-status is a usage error" \
  sh -c '[ "$1" = 2 ]' sh "$STATUS"
run_sa after-converge "specs/$FEATURE/spec.md" "$R1" --verify-status maybe
check "unknown verify-status value is a usage error" \
  sh -c '[ "$1" = 2 ]' sh "$STATUS"

reset_state
printf 'closed\n' > "$MS_STATE"
run_sa on-drained
check "on-drained with no eligible features dispatches nothing" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"

# ============================================================================
echo "== AC1/AC3: after-start advances to scheduling via an authenticated handoff =="

reset_state
run_sa after-start "specs/$FEATURE/spec.md" "$R1" --json
check "after-start succeeds" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "after-start dispatches the scheduler workflow" \
  sh -c 'grep -Fq "run agent-scheduler.yml" "$1"' sh "$DISPATCH_LOG"
check "the scheduler dispatch carries no convergence inputs" \
  sh -c '! grep -q "spec-converge" "$1"' sh "$DISPATCH_LOG"
check "the dispatch is authenticated with the workflow token" \
  sh -c 'grep -Fq "GH_TOKEN=workflow-token-dummy" "$1"' sh "$TOKEN_LOG"
check "the app token never reaches the dispatch boundary" \
  sh -c '! grep -q "app-token-dummy" "$1"' sh "$TOKEN_LOG"
check "after-start records the transition as JSON" \
  sh -c 'grep -Fq "\"transition\":\"after-start\"" "$1" && grep -Fq "\"decision\":\"dispatch\"" "$1" && grep -Fq "\"next\":\"scheduling\"" "$1"' \
  sh "$OUT_FILE"
check "after-start publishes a repository-native stage summary" \
  sh -c 'grep -qi "stage" "$1" && grep -qi "next" "$1" && grep -q "agent-scheduler.yml" "$1"' \
  sh "$SUMMARY_FILE"

reset_state
run_sa after-start "specs/018-noapp/spec.md" "$R1"
check "after-start rejects a missing approval record" \
  sh -c '[ "$1" = 1 ] && grep -qi "approval" "$2"' sh "$STATUS" "$OUT_ERR"
check "a rejected gate dispatches nothing" \
  sh -c '[ ! -s "$1" ]' sh "$DISPATCH_LOG"

reset_state
printf '1\n' > "$DISPATCH_RC"
run_sa after-start "specs/$FEATURE/spec.md" "$R1"
check "a failing dispatch fails the transition closed" \
  sh -c '[ "$1" = 1 ]' sh "$STATUS"
check "no stage summary is published for a failed transition" \
  sh -c '[ ! -s "$1" ]' sh "$SUMMARY_FILE"

# ============================================================================
echo "== AC2: after-converge routes remediation back to the scheduler =="

reset_state
run_sa after-converge "specs/$FEATURE/spec.md" "$R1" --verify-status ok --json
check "remediation-scheduled (no completion record) returns to the scheduler" \
  sh -c '[ "$1" = 0 ] && grep -Fq "run agent-scheduler.yml" "$2"' \
  sh "$STATUS" "$DISPATCH_LOG"
check "the remediation handoff records next=scheduling" \
  sh -c 'grep -Fq "\"decision\":\"dispatch\"" "$1" && grep -Fq "\"next\":\"scheduling\"" "$1"' \
  sh "$OUT_FILE"

reset_state
mkdir -p "$FX/specs/$FEATURE/convergence"
printf '{\n  "status": "complete",\n  "acceptance": "pass"\n}\n' \
  > "$FX/specs/$FEATURE/convergence/complete.json"
run_sa after-converge "specs/$FEATURE/spec.md" "$R1" --verify-status ok --json
check "verified completion dispatches nothing" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"
check "completion records the terminal decision with evidence" \
  sh -c 'grep -Fq "\"decision\":\"complete\"" "$1" && grep -Fq "convergence/complete.json" "$1"' \
  sh "$OUT_FILE"
rm -rf "$FX/specs/$FEATURE/convergence"

reset_state
run_sa after-converge "specs/$FEATURE/spec.md" "$R1" --verify-status blocked --json
check "blocked convergence starts no downstream run" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"
check "blocked is reported as a resumable waiting-on-human state" \
  sh -c 'grep -Fq "\"decision\":\"blocked\"" "$1" && grep -Fq "\"next\":\"human-decision\"" "$1"' \
  sh "$OUT_FILE"
check "the blocked summary names the waiting state" \
  sh -c 'grep -qi "blocked" "$1"' sh "$SUMMARY_FILE"

# ============================================================================
echo "== AC2: on-drained invokes convergence with the project budget =="

reset_state
run_sa on-drained "specs/$FEATURE/spec.md"
check "a drained feature dispatches the convergence workflow" \
  sh -c '[ "$1" = 0 ] && grep -Fq "run spec-converge.yml" "$2"' \
  sh "$STATUS" "$DISPATCH_LOG"
check "the convergence dispatch binds the approved spec and revision" \
  sh -c "grep -Fq -- '-f spec=specs/$FEATURE/spec.md' \"\$1\" && grep -Fq -- '-f revision=$R1' \"\$1\"" \
  sh "$DISPATCH_LOG"
check "the convergence dispatch respects the project-wide convergence budget" \
  sh -c 'grep -Fq -- "-f budget=3" "$1"' sh "$DISPATCH_LOG"
check "the drained transition publishes a stage summary" \
  sh -c "grep -q '$FEATURE' \"\$1\" && grep -q 'spec-converge.yml' \"\$1\" && grep -qi 'next' \"\$1\"" \
  sh "$SUMMARY_FILE"

reset_state
run_sa on-drained "specs/$FEATURE/spec.md" --json
check "json output is a single line" \
  sh -c '[ "$(wc -l < "$1" | tr -d " ")" = 1 ]' sh "$OUT_FILE"
check "json carries feature, revision, and evidence fields" \
  sh -c "grep -Fq '\"feature\":\"$FEATURE\"' \"\$1\" && grep -Fq '\"revision\":\"$R1\"' \"\$1\" && grep -Fq '\"dispatched\":\"spec-converge.yml\"' \"\$1\" && grep -Fq '\"next\":\"convergence\"' \"\$1\"" \
  sh "$OUT_FILE"

# ============================================================================
echo "== AC4: idempotent run keys deduplicate repeated and reordered events =="

reset_state
printf 'spec-converge specs/%s/spec.md @ %s\tin_progress\n' "$FEATURE" "$R1" > "$RUNS_TSV"
run_sa on-drained "specs/$FEATURE/spec.md"
check "an in-flight convergence run key suppresses the duplicate dispatch" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"
reset_state
printf 'spec-converge specs/%s/spec.md @ %s\tqueued\n' "$FEATURE" "$R1" > "$RUNS_TSV"
run_sa on-drained "specs/$FEATURE/spec.md" --json
check "a queued convergence run key suppresses duplicates too" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ] && grep -Fq "\"decision\":\"skip\"" "$3"' \
  sh "$STATUS" "$DISPATCH_LOG" "$OUT_FILE"

reset_state
printf 'closed\n' > "$MS_STATE"
run_sa on-drained "specs/$FEATURE/spec.md" --json
check "a closed (complete) feature milestone is terminal, never re-converged" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"

# ============================================================================
echo "== AC2/AC5: undrained, paused, cancelled, and budget-bounded transitions =="

reset_state
printf '12\t[%s/T003] late task\t\n' "$FEATURE" > "$OPEN_TSV"
run_sa on-drained "specs/$FEATURE/spec.md"
check "an undrained queue does not invoke convergence" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"

reset_state
printf '15\tblocked report\tblocked,agent-paused\n' > "$LABELS_TSV"
run_sa on-drained "specs/$FEATURE/spec.md"
check "a paused blocker holds the convergence transition" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"
check "the paused hold names the human control in the summary" \
  sh -c 'grep -qi "agent-paused" "$1"' sh "$SUMMARY_FILE"

reset_state
printf '15\tblocked report\tblocked,agent-cancelled\n' > "$LABELS_TSV"
run_sa on-drained "specs/$FEATURE/spec.md"
check "a cancelled blocker holds the convergence transition" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"

reset_state
printf '{"max_convergence_rounds": "zero"}\n' > "$BUDGET_FILE"
run_sa on-drained "specs/$FEATURE/spec.md"
check "an invalid project budget fails the transition closed" \
  sh -c '[ "$1" = 1 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"

reset_state
run_sa on-drained "specs/$FEATURE_B/spec.md"
check "a feature without planning artifacts is skipped, not dispatched" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"

reset_state
printf 'edited\n' >> "$FX/specs/$FEATURE/spec.md"
run_sa on-drained "specs/$FEATURE/spec.md"
check "a stale approval is never silently re-converged" \
  sh -c '[ "$1" = 0 ] && [ ! -s "$2" ]' sh "$STATUS" "$DISPATCH_LOG"
check "the stale skip points at re-approval" \
  sh -c 'grep -qi "stale" "$1"' sh "$SUMMARY_FILE"
git -C "$FX" checkout -- "specs/$FEATURE/spec.md"

# ============================================================================
echo "== discovery: one sweep advances every eligible feature exactly once =="

reset_state
run_sa on-drained
check "the sweep dispatches exactly one convergence run" \
  sh -c '[ "$1" = 0 ] && [ "$(wc -l < "$2" | tr -d " ")" = 1 ]' sh "$STATUS" "$DISPATCH_LOG"
check "the swept dispatch targets the drained feature" \
  sh -c "grep -Fq -- '-f spec=specs/$FEATURE/spec.md' \"\$1\"" sh "$DISPATCH_LOG"
check "the unplaned feature is reported, not dispatched" \
  sh -c "grep -q '$FEATURE_B' \"\$1\"" sh "$OUT_FILE"

# ============================================================================
echo "== wiring: workflows, docs =="

WFS="$REPO_ROOT/.github/workflows/spec-start.yml"
WFC="$REPO_ROOT/.github/workflows/spec-converge.yml"
WSA="$REPO_ROOT/.github/workflows/agent-scheduler.yml"

check "spec-start grants actions write for the authenticated handoff" \
  sh -c 'grep -q "actions: write" "$1"' sh "$WFS"
check "spec-converge grants actions write for the authenticated handoff" \
  sh -c 'grep -q "actions: write" "$1"' sh "$WFC"
check "scheduler grants actions write for the convergence dispatch" \
  sh -c 'grep -q "actions: write" "$1"' sh "$WSA"
check "spec-start advances to scheduling after issue generation" \
  sh -c 'grep -q "spec-advance.sh after-start" "$1"' sh "$WFS"
check "spec-converge advances after a validated verify outcome" \
  sh -c 'grep -q "spec-advance.sh after-converge" "$1" && grep -q -- "--verify-status" "$1"' sh "$WFC"
check "the converge advance step reuses the verify status output" \
  sh -c 'grep -A6 "name: Advance after convergence" "$1" | grep -q "steps.verify.outputs.status"' sh "$WFC"
check "the converge advance step never bypasses the persistence gating" \
  sh -c 'grep -A2 "name: Bind the convergence bundle manifest" "$1" | grep -q "steps.verify.outputs.status" && grep -A2 "name: Upload convergence artifacts" "$1" | grep -q "steps.verify.outputs.status"' sh "$WFC"
check "spec-converge carries the idempotent run-name stage key" \
  sh -c 'grep -Fq "run-name: spec-converge" "$1" && grep -Fq "github.event.inputs.spec" "$1" && grep -Fq "github.event.inputs.revision" "$1"' sh "$WFC"
check "scheduler probes drained features only in the advance job" \
  sh -c 'a=$(grep -n "^  repair:" "$1" | cut -d: -f1); b=$(grep -n "^  advance:" "$1" | cut -d: -f1); c=$(grep -n "spec-advance.sh on-drained" "$1" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$c" ] && [ "$b" -lt "$c" ]' sh "$WSA"
check "spec-advance hooks preserve the derived node pin in spec-start" \
  sh -c 'grep -qF "node-version: \${{ steps.node_pin.outputs.version }}" "$1"' sh "$WFS"
check "spec-advance hooks preserve the derived node pin in spec-converge" \
  sh -c 'grep -qF "node-version: \${{ steps.node_pin.outputs.version }}" "$1"' sh "$WFC"

DOC="$REPO_ROOT/docs/SPEC_ADVANCE.md"
check "the transition contract is documented" test -f "$DOC"
if [ -f "$DOC" ]; then
  check "the doc defines the three transition points" \
    sh -c 'grep -q "after-start" "$1" && grep -q "after-converge" "$1" && grep -q "on-drained" "$1"' sh "$DOC"
  check "the doc documents pause, cancel, and budget behavior" \
    sh -c 'grep -q "agent-paused" "$1" && grep -q "agent-cancelled" "$1" && grep -qi "budget" "$1"' sh "$DOC"
  check "the doc documents the resumable blocked state" \
    sh -c 'grep -qi "resumable" "$1"' sh "$DOC"
fi
check "README links the transition documentation" \
  sh -c 'grep -q "docs/SPEC_ADVANCE.md" "$1"' sh "$REPO_ROOT/README.md"
check "AGENTS.md points at the transition documentation" \
  sh -c 'grep -q "docs/SPEC_ADVANCE.md" "$1"' sh "$REPO_ROOT/AGENTS.md"

check "the coordinator delegates drained probing to the converge entrypoint" \
  sh -c 'grep -q "spec-converge-precheck.sh" "$1"' sh "$REPO_ROOT/scripts/spec-advance.sh"
check "the coordinator reads the project budget from the shared budget script" \
  sh -c 'grep -q "agent-budget.sh" "$1"' sh "$REPO_ROOT/scripts/spec-advance.sh"
check "the coordinator shells out to gh only, never an MCP server" \
  sh -c 'grep -q "gh workflow run" "$1" && ! grep -qi "mcp" "$1"' \
  sh "$REPO_ROOT/scripts/spec-advance.sh"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
