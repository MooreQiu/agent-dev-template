#!/usr/bin/env bash
# Acceptance tests for issue #24: track autonomous development from the
# approved spec to verified completion.
#
# Covers (issue #24 final acceptance, tracker slice; child-issue-owned
# behavior is covered by their own suites):
#   AC1 fixture walks approval -> planning -> scheduling -> in-progress ->
#      converging -> complete; every post-approval state names an autonomous
#      next action (no further human approval in normal execution)
#   AC2 a scheduled remediation issue (failed acceptance / rejected work)
#      keeps the loop autonomous: next action stays the agent sweep
#   AC3 the tracker itself cannot cause duplicate work: strictly read-only
#      gh usage and identical output on repeated runs
#   AC4 integrated-acceptance gaps surface as scheduled remediation state
#   AC5 exhausted budgets / genuine blockers produce an explicit resumable
#      blocked state with pointers to the evidence issues
#   AC6 completion is only reported when the record evidences every approved
#      requirement and integrated acceptance passed
#
# Run: bash tests/test-spec-track.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-spec-track.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

GH_LOG="$TMP/gh.log"
MOCK_BIN="$TMP/bin"
ISSUES_TSV="$TMP/issues.tsv"   # gh issue list --state all
OPEN_TSV="$TMP/open.tsv"       # gh issue list --milestone <f> --state open
MS_STATE="$TMP/ms-state"       # gh api ... select(.title ...) | .state
mkdir -p "$MOCK_BIN"
: > "$ISSUES_TSV"
: > "$OPEN_TSV"
printf 'closed\n' > "$MS_STATE"

failures=0
ok()   { echo "ok - $1"; }
bad()  { echo "FAIL - $1"; failures=$((failures + 1)); }

check() { # check <description> <command...>
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# --- mocked gh (records every call; serves lists from TSV fixtures) ---------
cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
if [ "$1" = repo ] && [ "$2" = view ]; then echo "acme/fixture"; exit 0; fi
if [ "$1" = api ]; then
  if printf '%s' "$*" | grep -q "select(.title"; then
    cat "$MS_STATE"; exit 0
  fi
  echo "[]"; exit 0
fi
if [ "$1" = issue ] && [ "$2" = list ]; then
  for a in "$@"; do
    if [ "$a" = "--milestone" ]; then cat "$OPEN_TSV"; exit 0; fi
  done
  cat "$ISSUES_TSV"; exit 0
fi
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"
export GH_LOG ISSUES_TSV OPEN_TSV MS_STATE

FEATURE="016-demo"

# --- fixture repository with an approved, fully scheduled feature -----------
make_fixture() { # make_fixture <dir>
  fx=$1
  mkdir -p "$fx/scripts" "$fx/specs/$FEATURE"
  cp "$REPO_ROOT/scripts/spec-track.sh" "$fx/scripts/spec-track.sh" 2>/dev/null
  git -C "$fx" init -q
  git -C "$fx" -c user.name=Test -c user.email=test@example.com \
    commit -q --allow-empty -m "init"
  cat > "$fx/specs/$FEATURE/spec.md" <<EOSPEC
# Spec: $FEATURE

## Requirements
- REQ1 The feature works end to end.
- REQ2 Export produces a signed artifact.
- REQ3 Reports are auditable.
EOSPEC
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
  printf '# Plan: %s\nApproach derived from the approved spec.\n' "$FEATURE" \
    > "$fx/specs/$FEATURE/plan.md"
  cat > "$fx/specs/$FEATURE/tasks.md" <<'EOTASK'
# Tasks: 016-demo

## Phase 1
- [ ] T001 Create project structure per implementation plan
- [ ] T002 [P] Configure linting and formatting tools
- [ ] T003 Implement service in src/services/ (depends on T001, T002)
- [ ] T004 Harden deployment
- [x] T005 Scaffold already completed
EOTASK
  git -C "$fx" add -A
  git -C "$fx" -c user.name=Test -c user.email=test@example.com commit -qm "artifacts"
}

FX="$TMP/repo"
make_fixture "$FX"
TR="$FX/scripts/spec-track.sh"
R1=$(cat "$FX/.approved")

OUT_ERR="$TMP/err.txt"
OUT_FILE="$TMP/out.txt"

run_tr() { # run_tr [args...] -> $STATUS / $OUT_FILE / $OUT_ERR
  : > "$GH_LOG"
  OUT=$(cd "$FX" && PATH="$MOCK_BIN:$PATH" bash "$TR" "$@" 2>"$OUT_ERR")
  STATUS=$?
  printf '%s\n' "$OUT" > "$OUT_FILE"
}

drained_remote() { # milestone drained: every task issue exists and is closed
  : > "$OPEN_TSV"
  cat > "$ISSUES_TSV" <<EOTSV
7	[$FEATURE/T001] Create project structure per implementation plan	CLOSED
8	[$FEATURE/T002] [P] Configure linting and formatting tools	CLOSED
9	[$FEATURE/T003] Implement service in src/services/	CLOSED
10	[$FEATURE/T004] Harden deployment	CLOSED
EOTSV
}

status_of()  { sed -n 's/.*"status":"\([a-z-]*\)".*/\1/p' "$1" | sed -n 1p; }
auto_of()    { sed -n 's/.*"autonomous":\([a-z]*\).*/\1/p' "$1" | sed -n 1p; }
next_of()    { sed -n 's/.*"next":"\([a-z-]*\)".*/\1/p' "$1" | sed -n 1p; }

restore_fixture() {
  git -C "$FX" checkout -- "specs/$FEATURE" 2>/dev/null
  rm -rf "$FX/specs/$FEATURE/convergence"
  printf 'closed\n' > "$MS_STATE"
}

VALID_TARGET=""
make_evidence() { # durable verification logs the evidence records can cite
  mkdir -p "$FX/verification"
  printf 'end-to-end run log\n' > "$FX/verification/REQ1-e2e.log"
  printf 'signed export log\n' > "$FX/verification/REQ2-signature.log"
  printf 'audit trail log\n' > "$FX/verification/REQ3-audit.log"
  VALID_TARGET=$(git -C "$FX" rev-parse HEAD)
}

valid_req2() { # the fully valid REQ2 evidence record line
  printf '{"id": "REQ2", "status": "verified", "method": "Signed export asserted", "evidence": "verification/REQ2-signature.log", "revision": "%s", "commit": "%s"}' \
    "$R1" "$VALID_TARGET"
}

record_with_req2() { # record_with_req2 <REQ2-json-line>
  # A complete record whose REQ1/REQ3 entries are fully evidenced; the REQ2
  # entry comes from the caller so each scenario can mutilate one field.
  make_evidence
  mkdir -p "$FX/specs/$FEATURE/convergence"
  cat > "$FX/specs/$FEATURE/convergence/complete.json" <<EOREC
{
  "feature": "$FEATURE",
  "spec": "specs/$FEATURE/spec.md",
  "revision": "$R1",
  "status": "complete",
  "acceptance": "pass",
  "evidence": "specs/$FEATURE/convergence/evidence/gate.json",
  "requirements": [
    {"id": "REQ1", "status": "verified", "method": "End-to-end flow checked", "evidence": "verification/REQ1-e2e.log", "revision": "$R1", "commit": "$VALID_TARGET"},
    $1,
    {"id": "REQ3", "status": "verified", "method": "Audit trail checked", "evidence": "verification/REQ3-audit.log", "revision": "$R1", "commit": "$VALID_TARGET"}
  ]
}
EOREC
}

valid_complete_record() { # every requirement carries a full evidence record
  make_evidence
  record_with_req2 "$(valid_req2)"
}

stray_commit() { # a commit that exists but is not in the current history
  BRANCH=$(git -C "$FX" rev-parse --abbrev-ref HEAD)
  git -C "$FX" checkout -q --detach
  printf 'stray\n' > "$FX/.stray"
  git -C "$FX" add .stray
  git -C "$FX" -c user.name=Test -c user.email=test@example.com commit -qm "stray"
  STRAY=$(git -C "$FX" rev-parse HEAD)
  git -C "$FX" checkout -q "$BRANCH"
}

# ============================================================================
echo "== usage and input gates =="

run_tr
check "no arguments prints usage and exits 2" \
  sh -c '[ "$1" = 2 ] && grep -q "Usage" "$2"' sh "$STATUS" "$OUT_ERR"

run_tr README.md
check "spec outside a feature directory is a usage error" \
  sh -c '[ "$1" = 2 ]' sh "$STATUS"

run_tr "specs/$FEATURE/missing.md" --json
check "missing spec file fails with an error" \
  sh -c '[ "$1" = 1 ] && grep -q "not found" "$2"' sh "$STATUS" "$OUT_ERR"

# ============================================================================
echo "== human gate: approval is the only routine human entry point =="

drained_remote
mv "$FX/specs/$FEATURE/approval.json" "$TMP/approval.bak"
run_tr "specs/$FEATURE/spec.md" --json
check "missing approval waits on a human, not an error" \
  sh -c '[ "$1" = 4 ] && grep -Fq "\"status\":\"awaiting-approval\"" "$2"' sh "$STATUS" "$OUT_FILE"
check "unapproved run is not autonomous and asks for approval" \
  sh -c 'grep -Fq "\"autonomous\":false" "$1" && grep -Fq "\"next\":\"approve\"" "$1"' sh "$OUT_FILE"
check "awaiting approval needs no remote access" test ! -s "$GH_LOG"
mv "$TMP/approval.bak" "$FX/specs/$FEATURE/approval.json"

printf -- '- REQ4 Sneaked in after approval.\n' >> "$FX/specs/$FEATURE/spec.md"
run_tr "specs/$FEATURE/spec.md" --json
check "spec edited after approval waits for re-approval, never proceeds" \
  sh -c '[ "$1" = 4 ] && grep -Fq "\"status\":\"awaiting-approval\"" "$2"' sh "$STATUS" "$OUT_FILE"
check "stale approval names re-approval in the evidence log" \
  sh -c 'grep -qi "stale" "$1" && grep -qi "re-approval" "$1"' sh "$OUT_ERR"
restore_fixture

sed 's/"approved_by": "tester"/"approved_by": ""/' "$FX/specs/$FEATURE/approval.json" \
  > "$TMP/no-approver.json" && mv "$TMP/no-approver.json" "$FX/specs/$FEATURE/approval.json"
run_tr "specs/$FEATURE/spec.md" --json
check "approval record without a human approver waits on a human" \
  sh -c '[ "$1" = 4 ] && grep -Fq "\"status\":\"awaiting-approval\"" "$2"' sh "$STATUS" "$OUT_FILE"
restore_fixture

# ============================================================================
echo "== AC1: the chain from approved spec to completion stays autonomous =="

rm "$FX/specs/$FEATURE/plan.md" "$FX/specs/$FEATURE/tasks.md"
drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "missing planning artifacts point at autonomous planning" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"planning\"" "$2" && grep -Fq "\"autonomous\":true" "$2"' \
  sh "$STATUS" "$OUT_FILE"
check "planning state names the spec-start planning action" \
  sh -c 'grep -Fq "\"next\":\"plan\"" "$1"' sh "$OUT_FILE"
check "planning state needs no remote access" test ! -s "$GH_LOG"
restore_fixture

cat > "$ISSUES_TSV" <<EOTSV
7	[$FEATURE/T001] Create project structure per implementation plan	CLOSED
EOTSV
: > "$OPEN_TSV"
run_tr "specs/$FEATURE/spec.md" --json
check "unchecked tasks without issues point at autonomous issue generation" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"scheduling\"" "$2" && grep -Fq "\"next\":\"generate-issues\"" "$2"' \
  sh "$STATUS" "$OUT_FILE"
check "scheduling state counts the unscheduled tasks" \
  sh -c 'grep -Fq "\"unscheduled_tasks\":3" "$1" && grep -Fq "\"tasks_total\":5" "$1" && grep -Fq "\"tasks_done\":1" "$1"' \
  sh "$OUT_FILE"

drained_remote
printf '31\t[%s/T002] [P] Configure linting and formatting tools\tfalse\n' "$FEATURE" > "$OPEN_TSV"
run_tr "specs/$FEATURE/spec.md" --json
check "open queue work points at the autonomous agent sweep" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"in-progress\"" "$2" && grep -Fq "\"next\":\"sweep\"" "$2"' \
  sh "$STATUS" "$OUT_FILE"
check "in-progress reports the open issue count" \
  sh -c 'grep -Fq "\"open_issues\":1" "$1"' sh "$OUT_FILE"

drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "drained queue without a completion record points at convergence" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"converging\"" "$2" && grep -Fq "\"next\":\"converge\"" "$2"' \
  sh "$STATUS" "$OUT_FILE"

valid_complete_record
drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "valid completion record reports verified completion" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"complete\"" "$2" && grep -Fq "\"next\":\"none\"" "$2"' \
  sh "$STATUS" "$OUT_FILE"

# The full fixture chain: after the single human approval, every observed
# state except the terminal ones reports an autonomous next action.
rm -rf "$FX/specs/$FEATURE/convergence"
: > "$OPEN_TSV"
printf '7\t[%s/T001] Create project structure	CLOSED\n' "$FEATURE" > "$ISSUES_TSV"
CHAIN=""
{
  run_tr "specs/$FEATURE/spec.md" --json; CHAIN="$CHAIN $(status_of "$OUT_FILE"):$(auto_of "$OUT_FILE")"
  drained_remote
  printf '31\t[%s/T004] Harden deployment\tfalse\n' "$FEATURE" > "$OPEN_TSV"
  run_tr "specs/$FEATURE/spec.md" --json; CHAIN="$CHAIN $(status_of "$OUT_FILE"):$(auto_of "$OUT_FILE")"
  : > "$OPEN_TSV"
  run_tr "specs/$FEATURE/spec.md" --json; CHAIN="$CHAIN $(status_of "$OUT_FILE"):$(auto_of "$OUT_FILE")"
  valid_complete_record
  run_tr "specs/$FEATURE/spec.md" --json; CHAIN="$CHAIN $(status_of "$OUT_FILE"):$(auto_of "$OUT_FILE")"
}
check "fixture walks scheduling -> in-progress -> converging -> complete autonomously" \
  sh -c '[ "$1" = " scheduling:true in-progress:true converging:true complete:false" ]' sh "$CHAIN"
restore_fixture

# ============================================================================
echo "== AC2 + AC4: remediation of failed acceptance stays autonomous =="

drained_remote
printf '41\t[%s/G001] Signed export artifact is not implemented (attempt 1)\tfalse\n' "$FEATURE" > "$OPEN_TSV"
run_tr "specs/$FEATURE/spec.md" --json
check "scheduled remediation keeps the loop in autonomous progress" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"in-progress\"" "$2" && grep -Fq "\"next\":\"sweep\"" "$2"' \
  sh "$STATUS" "$OUT_FILE"
: > "$OPEN_TSV"

# ============================================================================
echo "== AC3: tracking cannot cause duplicate work =="

printf '31\t[%s/T004] Harden deployment\tfalse\n' "$FEATURE" > "$OPEN_TSV"
printf '23\t[%s/G001] Signed export artifact is not implemented (blocked)\ttrue\n' "$FEATURE" >> "$OPEN_TSV"
run_tr "specs/$FEATURE/spec.md" --json
check "open work continues while blocked reports are only surfaced" \
  sh -c 'grep -Fq "\"status\":\"in-progress\"" "$1" && grep -Fq "\"blocked_issues\":1" "$1"' sh "$OUT_FILE"
check "tracker only reads from gh (no create, edit, or mutation)" \
  sh -c '! grep -q "issue create" "$1" && ! grep -q "issue edit" "$1" && ! grep -q -- "-X PATCH" "$1" && ! grep -q "issue close" "$1"' \
  sh "$GH_LOG"
cp "$OUT_FILE" "$TMP/first.json"
run_tr "specs/$FEATURE/spec.md" --json
check "repeated tracking returns identical status (duplicate-safe)" \
  sh -c 'cmp -s "$1" "$2"' sh "$TMP/first.json" "$OUT_FILE"
: > "$OPEN_TSV"

# ============================================================================
echo "== AC5: exhausted budgets and blockers are explicit and resumable =="

drained_remote
printf '23\t[%s/G001] Signed export artifact is not implemented (blocked)\ttrue\n' "$FEATURE" > "$OPEN_TSV"
run_tr "specs/$FEATURE/spec.md" --json
check "blocked-only queue is an explicit non-autonomous state" \
  sh -c '[ "$1" = 4 ] && grep -Fq "\"status\":\"blocked\"" "$2" && grep -Fq "\"autonomous\":false" "$2"' \
  sh "$STATUS" "$OUT_FILE"
check "blocked state asks for a human decision as the next action" \
  sh -c 'grep -Fq "\"next\":\"human-decision\"" "$1"' sh "$OUT_FILE"
check "blocked evidence issue is listed for the human" \
  sh -c 'grep -Fq "#23" "$1" && grep -Fq "016-demo/G001" "$1"' sh "$OUT_ERR"
: > "$OPEN_TSV"
run_tr "specs/$FEATURE/spec.md" --json
check "resolving the blocked work resumes the autonomous chain" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"converging\"" "$2" && grep -Fq "\"autonomous\":true" "$2"' \
  sh "$STATUS" "$OUT_FILE"

# ============================================================================
echo "== AC6: completion requires requirement-level and integration evidence =="

valid_complete_record
drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "completion evidences every approved requirement" \
  sh -c 'grep -Fq "\"requirements_total\":3" "$1" && grep -Fq "\"requirements_evidenced\":3" "$1"' sh "$OUT_FILE"
check "completion reports the closed feature milestone" \
  sh -c 'grep -Fq "\"milestone\":\"closed\"" "$1"' sh "$OUT_FILE"

sed '/"id": "REQ3"/d' "$FX/specs/$FEATURE/convergence/complete.json" \
  > "$TMP/short.json" && mv "$TMP/short.json" "$FX/specs/$FEATURE/convergence/complete.json"
run_tr "specs/$FEATURE/spec.md" --json
check "record missing a requirement is not completion" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"converging\"" "$2"' sh "$STATUS" "$OUT_FILE"
check "missing requirement is named so convergence can rerun" \
  sh -c 'grep -Fq "REQ3" "$1"' sh "$OUT_FILE"
restore_fixture

valid_complete_record
sed 's/"acceptance": "pass"/"acceptance": "fail"/' "$FX/specs/$FEATURE/convergence/complete.json" \
  > "$TMP/fail.json" && mv "$TMP/fail.json" "$FX/specs/$FEATURE/convergence/complete.json"
run_tr "specs/$FEATURE/spec.md" --json
check "record with failing acceptance is not completion" \
  sh -c 'grep -Fq "\"status\":\"converging\"" "$1" && grep -qi "acceptance" "$1"' sh "$OUT_FILE"
restore_fixture

valid_complete_record
sed 's/"evidence": "verification\/REQ2-signature.log"/"evidence": ""/' \
  "$FX/specs/$FEATURE/convergence/complete.json" \
  > "$TMP/empty.json" && mv "$TMP/empty.json" "$FX/specs/$FEATURE/convergence/complete.json"
run_tr "specs/$FEATURE/spec.md" --json
check "requirement without evidence is not completion" \
  sh -c 'grep -Fq "\"status\":\"converging\"" "$1" && grep -Fq "\"requirements_evidenced\":2" "$1"' sh "$OUT_FILE"
restore_fixture

# ============================================================================
echo "== issue #45: evidence records must be verifiable, not just non-empty =="

make_evidence

record_with_req2 "$(valid_req2 | sed 's/"status": "verified"/"status": "integrated-acceptance"/; s#"verification/REQ2-signature.log"#"specs/016-demo/convergence/evidence/gate.json"#')"
drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "a generic integration record cannot evidence a requirement" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"converging\"" "$2"' sh "$STATUS" "$OUT_FILE"
check "the generic record is named so convergence can rerun" \
  sh -c 'grep -Fq "REQ2" "$1" && grep -Fq "not a verified record" "$1"' sh "$OUT_FILE"
restore_fixture

record_with_req2 "$(valid_req2 | sed 's#"verification/REQ2-signature.log"#"verification/nonexistent.log"#')"
drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "evidence at a nonexistent location is not completion" \
  sh -c 'grep -Fq "\"status\":\"converging\"" "$1" && grep -Fq "evidence location does not exist" "$1"' sh "$OUT_FILE"
check "the nonexistent evidence keeps the loop autonomous" \
  sh -c 'grep -Fq "\"autonomous\":true" "$1" && grep -Fq "\"next\":\"converge\"" "$1"' sh "$OUT_FILE"
restore_fixture

record_with_req2 "$(valid_req2 | sed "s/\"revision\": \"$R1\"/\"revision\": \"0000000000000000000000000000000000000000\"/")"
drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "evidence bound to a mismatched spec revision is not completion" \
  sh -c 'grep -Fq "\"status\":\"converging\"" "$1" && grep -Fq "different spec revision" "$1"' sh "$OUT_FILE"
restore_fixture

stray_commit
record_with_req2 "$(valid_req2 | sed "s/\"commit\": \"$VALID_TARGET\"/\"commit\": \"$STRAY\"/")"
drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "evidence collected on a stale commit is not completion" \
  sh -c 'grep -Fq "\"status\":\"converging\"" "$1" && grep -Fq "not in the current history" "$1"' sh "$OUT_FILE"
restore_fixture

record_with_req2 "$(valid_req2 | sed 's/"commit": "[0-9a-f]*"/"commit": "1111111111111111111111111111111111111111"/')"
drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "evidence citing a nonexistent commit is not completion" \
  sh -c 'grep -Fq "\"status\":\"converging\"" "$1" && grep -Fq "no valid code commit" "$1"' sh "$OUT_FILE"
restore_fixture

record_with_req2 "$(valid_req2 | sed 's/"method": "Signed export asserted"/"method": ""/')"
drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "a record without a verification method is not completion" \
  sh -c 'grep -Fq "\"status\":\"converging\"" "$1" && grep -Fq "no verification method" "$1"' sh "$OUT_FILE"
restore_fixture

valid_complete_record
drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "a fully evidenced record with valid bindings proves completion" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"complete\"" "$2" && grep -Fq "\"requirements_evidenced\":3" "$2"' \
  sh "$STATUS" "$OUT_FILE"
restore_fixture

valid_complete_record
printf 'open\n' > "$MS_STATE"
run_tr "specs/$FEATURE/spec.md" --json
check "an open milestone warns but the record still proves completion" \
  sh -c 'grep -Fq "\"status\":\"complete\"" "$1" && grep -Fq "\"milestone\":\"open\"" "$1" && grep -Fq "milestone is still open" "$1"' \
  sh "$OUT_FILE"
restore_fixture

# ============================================================================
echo "== output contract =="

drained_remote
run_tr "specs/$FEATURE/spec.md" --json
check "json output is a single machine-readable line" \
  sh -c '[ "$(wc -l < "$1" | tr -d " ")" = 1 ] && grep -Fq "\"feature\":\"016-demo\"" "$1"' sh "$OUT_FILE"
run_tr "specs/$FEATURE/spec.md"
check "human output prints a summary line without JSON" \
  sh -c 'grep -q "^summary: feature=016-demo status=converging autonomous=true next=converge" "$1" && ! grep -q "\"status\"" "$1"' sh "$OUT_FILE"

# ============================================================================
echo "== wiring: workflow, docs, read-only remote access =="

WF="$REPO_ROOT/.github/workflows/spec-track.yml"
check "spec-track workflow exists" test -f "$WF"
if [ -f "$WF" ]; then
  check "workflow is human-triggered with a spec input" \
    sh -c 'grep -q "workflow_dispatch" "$1" && grep -q "spec:" "$1"' sh "$WF"
  check "workflow grants read-only permissions" \
    sh -c 'grep -q "issues: read" "$1" && ! grep -q "issues: write" "$1" && ! grep -q "contents: write" "$1"' sh "$WF"
  check "workflow maps waiting-on-human to a notice, not a failure" \
    sh -c 'grep -q "::notice::" "$1"' sh "$WF"
  check "workflow runs the tracker entrypoint" \
    sh -c 'grep -q "scripts/spec-track.sh" "$1"' sh "$WF"
  check "workflow fetches full history so the revision resolves" \
    sh -c 'grep -q "fetch-depth: 0" "$1"' sh "$WF"
fi

DOC="$REPO_ROOT/docs/SPEC_TRACK.md"
check "tracking doc exists" test -f "$DOC"
if [ -f "$DOC" ]; then
  check "doc defines the state machine and next actions" \
    sh -c 'grep -q "awaiting-approval" "$1" && grep -q "in-progress" "$1" && grep -q "converging" "$1" && grep -q "complete" "$1"' sh "$DOC"
  check "doc documents blocked resumability and human gates" \
    sh -c 'grep -qi "blocked" "$1" && grep -qi "resum" "$1"' sh "$DOC"
  check "doc states the tracker never enqueues work" \
    sh -c 'grep -qi "只读\|never" "$1"' sh "$DOC"
fi
check "AGENTS.md points at the tracking entrypoint documentation" \
  sh -c 'grep -q "docs/SPEC_TRACK.md" "$1"' sh "$REPO_ROOT/AGENTS.md"

check "entrypoint only reads from gh, never an MCP server" \
  sh -c 'grep -q "gh issue list" "$1" && ! grep -q "issue create" "$1" && ! grep -q -- "-X PATCH" "$1" && ! grep -qi "mcp" "$1"' \
  sh "$REPO_ROOT/scripts/spec-track.sh"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
