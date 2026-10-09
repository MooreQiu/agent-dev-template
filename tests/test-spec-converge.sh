#!/usr/bin/env bash
# Acceptance tests for issue #21: verify project completion against the
# approved spec and schedule remaining work.
#
# Covers (issue #21 acceptance criteria):
#   AC1 after the applicable task queue drains, evaluate the integrated
#      target branch against the approved spec, plan, requirements
#   AC2 configured integration/end-to-end acceptance and build validation
#      with requirement-to-evidence traceability
#   AC3 convergence findings become deduplicated remediation tasks within
#      approved scope and automatically resume scheduling
#   AC4 finite convergence budget; unresolved requirements are reported as
#      blocked rather than claiming completion
#   AC5 project-complete only when no required gaps remain and integrated
#      acceptance passes; approved spec and plan are preserved
#   AC6 the tests themselves
#
# Also covers (issue #43 acceptance criteria):
#   AC7 an undrained queue maps to an explicit deferred precheck outcome
#      and never evaluates, schedules remediation, or publishes completion
#   AC8 a drained queue maps to ready; invalid approval or other precheck
#      errors fail closed with the precheck exit code
#   AC9 behavioral regression tests for the workflow control flow
#      (deferred, ready, and failed precheck outcomes)
#
# Run: bash tests/test-spec-converge.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-spec-converge.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

GH_LOG="$TMP/gh.log"
GATE_LOG="$TMP/gate.log"
GATE_RC="$TMP/gate-rc"
MOCK_BIN="$TMP/bin"
CREATED="$TMP/created"
COUNTER="$TMP/counter"
ISSUES_TSV="$TMP/issues.tsv"       # gh issue list --state all (closed + open)
OPEN_TSV="$TMP/open.tsv"           # gh issue list --milestone <f> --state open
MS_JSON="$TMP/milestones.json"     # gh api repos/<repo>/milestones
mkdir -p "$MOCK_BIN" "$CREATED"
: > "$ISSUES_TSV"
: > "$OPEN_TSV"
printf '[{"title":"016-demo","number":3}]' > "$MS_JSON"
printf '0\n' > "$GATE_RC"

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
  for a in "$@"; do
    if [ "$a" = "-X" ]; then exit 0; fi # mutation recorded above only
  done
  # Emulate the one --jq filter the entrypoint uses against the fixture.
  if printf '%s' "$*" | grep -q "select(.title"; then
    sed -n "s/.*\"title\":\"$MILESTONE_TITLE\",\"number\":\([0-9]*\).*/\1/p" "$MS_JSON"
    exit 0
  fi
  cat "$MS_JSON"; exit 0
fi
if [ "$1" = issue ] && [ "$2" = list ]; then
  for a in "$@"; do
    if [ "$a" = "--milestone" ]; then cat "$OPEN_TSV"; exit 0; fi
  done
  cat "$ISSUES_TSV"; exit 0
fi
if [ "$1" = issue ] && [ "$2" = create ]; then
  shift 2
  title= bodyfile= labels= milestone=
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)     title=$2; shift 2 ;;
      --body-file) bodyfile=$2; shift 2 ;;
      --label)     labels="$labels $2"; shift 2 ;;
      --milestone) milestone=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  n=$(cat "$COUNTER" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1)); printf '%s\n' "$n" > "$COUNTER"
  printf '%s\n' "$title" > "$CREATED/$n.title"
  if [ -n "$bodyfile" ] && [ -f "$bodyfile" ]; then
    cp "$bodyfile" "$CREATED/$n.body"
  else
    : > "$CREATED/$n.body"
  fi
  printf '%s\n' "$labels" > "$CREATED/$n.labels"
  printf '%s\n' "$milestone" > "$CREATED/$n.milestone"
  echo "https://github.com/acme/fixture/issues/$n"
  exit 0
fi
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"
export GH_LOG ISSUES_TSV OPEN_TSV MS_JSON COUNTER CREATED

# --- stubbed ci-gate (records the call; exit + evidence from control files) -
mkdir -p "$MOCK_BIN/../gate"
cat > "$TMP/gate-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "ci-gate $*" >> "$GATE_LOG"
mode=$1; shift
ed=".ci-evidence"
while [ $# -gt 0 ]; do
  case "$1" in
    --evidence-dir) ed=$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$ed"
rc=$(cat "$GATE_RC" 2>/dev/null); case "$rc" in ''|*[!0-9]*) rc=0 ;; esac
printf '{\n  "checks": [\n    {"name": "test", "command": "npm test", "exit": %s, "log": "test.log"}\n  ]\n}\n' "$rc" > "$ed/gate.json"
printf 'suite output (exit %s)\n' "$rc" > "$ed/test.log"
exit "$rc"
EOF
export GATE_LOG GATE_RC

FEATURE="016-demo"
export MILESTONE_TITLE="$FEATURE"

# --- fixture repository with an approved, fully scheduled feature -----------
make_fixture() { # make_fixture <dir>
  fx=$1
  mkdir -p "$fx/scripts" "$fx/specs/$FEATURE"
  cp "$REPO_ROOT/scripts/spec-converge.sh" "$fx/scripts/spec-converge.sh" 2>/dev/null
  cp "$REPO_ROOT/scripts/spec-converge-precheck.sh" "$fx/scripts/spec-converge-precheck.sh" 2>/dev/null
  cp "$TMP/gate-stub.sh" "$fx/scripts/ci-gate.sh" 2>/dev/null
  chmod +x "$fx/scripts/ci-gate.sh" 2>/dev/null
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
SC="$FX/scripts/spec-converge.sh"
R1=$(cat "$FX/.approved")

OUT_ERR="$TMP/err.txt"
OUT_FILE="$TMP/out.txt"

run_sc() { # run_sc [args...] -> $STATUS / $OUT_FILE / $OUT_ERR
  : > "$GH_LOG"
  : > "$GATE_LOG"
  OUT=$(cd "$FX" && PATH="$MOCK_BIN:$PATH" bash "$SC" "$@" 2>"$OUT_ERR")
  STATUS=$?
  printf '%s\n' "$OUT" > "$OUT_FILE"
}

PRE_OUT="$TMP/pre-outcome" # captured step output (a $GITHUB_OUTPUT stand-in)
PC="$FX/scripts/spec-converge-precheck.sh"

run_pre() { # run_pre [args...] -> $STATUS / $OUT_FILE / $OUT_ERR / $PRE_OUT
  : > "$GH_LOG"
  : > "$GATE_LOG"
  : > "$PRE_OUT"
  OUT=$(cd "$FX" && PATH="$MOCK_BIN:$PATH" GITHUB_OUTPUT="$PRE_OUT" \
    bash "$PC" "$@" 2>"$OUT_ERR")
  STATUS=$?
  printf '%s\n' "$OUT" > "$OUT_FILE"
}

reset_scenario() { # drained-by-default mock state between scenarios
  rm -rf "$CREATED"; mkdir -p "$CREATED"
  rm -f "$COUNTER"
  : > "$ISSUES_TSV"
  : > "$OPEN_TSV"
  printf '0\n' > "$GATE_RC"
  printf '7\t[%s/T001] Create project structure per implementation plan\tCLOSED\n' "$FEATURE" > "$ISSUES_TSV"
  printf '8\t[%s/T002] [P] Configure linting and formatting tools\tCLOSED\n' "$FEATURE" >> "$ISSUES_TSV"
  printf '9\t[%s/T003] Implement service in src/services/\tCLOSED\n' "$FEATURE" >> "$ISSUES_TSV"
  printf '10\t[%s/T004] Harden deployment\tCLOSED\n' "$FEATURE" >> "$ISSUES_TSV"
}

restore_fixture() { # reset fixture files to the approved state
  git -C "$FX" checkout -- "specs/$FEATURE" 2>/dev/null
  rm -rf "$FX/specs/$FEATURE/convergence"
}

immutable_hashes() { # prints blob hashes of the artifacts that must not change
  git -C "$FX" hash-object "specs/$FEATURE/spec.md" \
    "specs/$FEATURE/plan.md" "specs/$FEATURE/tasks.md" \
    "specs/$FEATURE/approval.json"
}

gap_findings() { # gap_findings <id> <requirement> <kind> <summary>
  cat > "$FX/specs/$FEATURE/findings.jsonl" <<EOF
{"id": "$1", "requirement": "$2", "kind": "$3", "summary": "$4", "evidence": "converge session $1"}
EOF
}

# ============================================================================
echo "== gates: approval, immutable revision, usage =="

run_sc
check "no arguments prints usage and exits 2" \
  sh -c '[ "$1" = 2 ] && grep -q "Usage" "$2"' sh "$STATUS" "$OUT_ERR"

run_sc "specs/$FEATURE/spec.md" "$R1" --dry-run
check "drained fixture passes the gates in dry-run" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "dry-run never calls gh" test ! -s "$GH_LOG"
check "dry-run does not run acceptance" test ! -s "$GATE_LOG"

mv "$FX/specs/$FEATURE/approval.json" "$TMP/approval.bak"
run_sc "specs/$FEATURE/spec.md" "$R1"
check "missing approval record fails with actionable error" \
  sh -c '[ "$1" != 0 ] && grep -q "approval" "$2"' sh "$STATUS" "$OUT_ERR"
mv "$TMP/approval.bak" "$FX/specs/$FEATURE/approval.json"

printf -- '- REQ4 Sneaked in after approval.\n' >> "$FX/specs/$FEATURE/spec.md"
run_sc "specs/$FEATURE/spec.md" "$R1"
check "spec edited after approval is stale, never silently replaced" \
  sh -c '[ "$1" != 0 ] && grep -qi "stale" "$2"' sh "$STATUS" "$OUT_ERR"
restore_fixture

# ============================================================================
echo "== AC1: convergence waits for the applicable task queue to drain =="

reset_scenario
printf '31\t[%s/T009] Human filed bug\tOPEN\n' "$FEATURE" > "$OPEN_TSV"
run_sc "specs/$FEATURE/spec.md" "$R1" --json
check "open milestone issue keeps the queue undrained (exit 3)" \
  sh -c '[ "$1" = 3 ] && grep -qi "not drained" "$2"' sh "$STATUS" "$OUT_ERR"
check "undrained queue creates no issues and runs no acceptance" \
  sh -c '! grep -q "issue create" "$1" && ! test -s "$2"' sh "$GH_LOG" "$GATE_LOG"

reset_scenario
grep -v 'T004' "$ISSUES_TSV" > "$TMP/filtered" && mv "$TMP/filtered" "$ISSUES_TSV"
run_sc "specs/$FEATURE/spec.md" "$R1"
check "unchecked task without an issue keeps the queue undrained" \
  sh -c '[ "$1" = 3 ] && grep -q "T004" "$2"' sh "$STATUS" "$OUT_ERR"

reset_scenario
run_sc "specs/$FEATURE/spec.md" "$R1" --precheck --json
check "precheck on a drained queue exits 0 without side effects" \
  sh -c '[ "$1" = 0 ] && ! grep -q "issue create" "$2"' sh "$STATUS" "$GH_LOG"
check "precheck queries the milestone queue" \
  sh -c 'grep -q -- "--milestone" "$1" && grep -q "state open" "$1"' sh "$GH_LOG"

reset_scenario
run_sc "specs/$FEATURE/spec.md" "$R1"
check "drained queue proceeds to integrated acceptance" test -s "$GATE_LOG"
restore_fixture

# ============================================================================
echo "== AC7-AC9 (issue #43): precheck outcome controls workflow steps =="

reset_scenario
printf '31\t[%s/T009] Human filed bug\tOPEN\n' "$FEATURE" > "$OPEN_TSV"
run_pre "specs/$FEATURE/spec.md" "$R1" --json
check "undrained queue maps to outcome=deferred with exit 0" \
  sh -c '[ "$1" = 0 ] && grep -Fxq "outcome=deferred" "$2"' sh "$STATUS" "$PRE_OUT"
check "deferred outcome is also explicit on stdout" \
  sh -c 'grep -Fxq "outcome=deferred" "$1"' sh "$OUT_FILE"
check "deferred precheck announces itself as a notice, not a failure" \
  sh -c 'grep -Fq "::notice::" "$1" && grep -qi "not drained" "$1"' sh "$OUT_FILE"
check "deferred precheck queried the queue before deciding" \
  sh -c 'grep -q -- "--milestone" "$1" && grep -q "state open" "$1"' sh "$GH_LOG"
check "deferred precheck never evaluates, schedules remediation, or publishes" \
  sh -c '! grep -q "issue create" "$1" && ! grep -q -- "-X PATCH" "$1" && ! test -s "$2"' \
  sh "$GH_LOG" "$GATE_LOG"
check "no completion record appears for a deferred convergence" \
  test ! -f "$FX/specs/$FEATURE/convergence/complete.json"

reset_scenario
printf '31\t[%s/T009] Human filed bug\tOPEN\n' "$FEATURE" > "$OPEN_TSV"
OUT=$(cd "$FX" && PATH="$MOCK_BIN:$PATH" env -u GITHUB_OUTPUT \
  bash "$PC" "specs/$FEATURE/spec.md" "$R1" 2>"$OUT_ERR")
STATUS=$?
check "deferred outcome is printed even outside Actions" \
  sh -c '[ "$1" = 0 ] && grep -Fxq "outcome=deferred" "$2"' sh "$STATUS" "$OUT"

reset_scenario
run_pre "specs/$FEATURE/spec.md" "$R1" --json
check "drained queue maps to outcome=ready with exit 0" \
  sh -c '[ "$1" = 0 ] && grep -Fxq "outcome=ready" "$2"' sh "$STATUS" "$PRE_OUT"
check "ready precheck keeps the queue-drained JSON summary" \
  sh -c 'grep -Fq "\"status\":\"queue-drained\"" "$1"' sh "$OUT_FILE"
check "ready precheck runs no acceptance and creates nothing" \
  sh -c '! grep -q "issue create" "$1" && ! test -s "$2"' sh "$GH_LOG" "$GATE_LOG"

reset_scenario
printf -- '- REQ4 Sneaked in after approval.\n' >> "$FX/specs/$FEATURE/spec.md"
run_pre "specs/$FEATURE/spec.md" "$R1" --json
check "invalid approval fails closed preserving the precheck exit code" \
  sh -c '[ "$1" = 1 ] && grep -Fxq "outcome=failed" "$2" && grep -qi "stale" "$3"' \
  sh "$STATUS" "$PRE_OUT" "$OUT_ERR"
check "failed precheck is an explicit error annotation" \
  sh -c 'grep -Fq "::error::" "$1"' sh "$OUT_FILE"
check "failed precheck never reaches gh" test ! -s "$GH_LOG"
restore_fixture

reset_scenario
grep -v 'T004' "$ISSUES_TSV" > "$TMP/filtered" && mv "$TMP/filtered" "$ISSUES_TSV"
run_pre "specs/$FEATURE/spec.md"
check "unchecked task without an issue still defers via the adapter" \
  sh -c '[ "$1" = 0 ] && grep -Fxq "outcome=deferred" "$2"' sh "$STATUS" "$PRE_OUT"

run_pre
check "usage error fails closed as outcome=failed exit 2" \
  sh -c '[ "$1" = 2 ] && grep -Fxq "outcome=failed" "$2"' sh "$STATUS" "$PRE_OUT"

# ============================================================================
echo "== AC2 + AC3: missing requirement despite closed issues becomes a task =="

reset_scenario
gap_findings G001 REQ2 missing "Signed export artifact is not implemented"
BEFORE=$(immutable_hashes)
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl" --json
AFTER=$(immutable_hashes)
check "gap against closed issues schedules remediation (exit 0)" \
  sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "json reports remediation-scheduled, not complete" \
  sh -c 'grep -Fq "\"status\":\"remediation-scheduled\"" "$1"' sh "$OUT_FILE"
check "one deduplicated remediation issue is created" \
  sh -c '[ "$(cat "$1")" = 1 ]' sh "$COUNTER"
check "remediation title uses the finding identity and attempt" \
  sh -c 'grep -Fq "[016-demo/G001] Signed export artifact is not implemented (attempt 1)" "$1"' \
  sh "$CREATED/1.title"
check "remediation issue resumes scheduling via ready-for-agent" \
  sh -c 'grep -q "ready-for-agent" "$1" && ! grep -q "blocked" "$1"' sh "$CREATED/1.labels"
check "remediation issue joins the feature milestone" \
  sh -c '[ "$(cat "$1")" = "016-demo" ]' sh "$CREATED/1.milestone"
check "body traces the finding to the requirement and spec revision" \
  sh -c 'grep -Fq "Requirement: REQ2" "$1" && grep -Fq "Spec: specs/016-demo/spec.md" "$1" && grep -Fq "@ $2" "$1"' \
  sh "$CREATED/1.body" "$R1"
check "body carries finding kind, summary and evidence" \
  sh -c 'grep -Fq "Kind: missing" "$1" && grep -Fq "Summary: Signed export artifact" "$1" && grep -Fq "Evidence: converge session G001" "$1"' \
  sh "$CREATED/1.body"
check "approved spec, plan, tasks and approval record are preserved" \
  sh -c '[ "$1" = "$2" ]' sh "$BEFORE" "$AFTER"
check "no completion is published while a gap remains" \
  sh -c '! grep -q -- "-X PATCH" "$1" && ! test -f "$2"' sh "$GH_LOG" "$FX/specs/$FEATURE/convergence/complete.json"
restore_fixture

# ============================================================================
echo "== AC2: integration regressions synthesize a gap with evidence =="

reset_scenario
printf '1\n' > "$GATE_RC"
run_sc "specs/$FEATURE/spec.md" "$R1" --json
check "failing integrated acceptance schedules remediation (exit 0)" \
  sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "json records the failed acceptance" \
  sh -c 'grep -Fq "\"acceptance\":\"fail\"" "$1"' sh "$OUT_FILE"
check "regression issue is created for the acceptance gap" \
  sh -c '[ "$(cat "$1")" = 1 ] && grep -Fq "[016-demo/integrated-acceptance]" "$2"' \
  sh "$COUNTER" "$CREATED/1.title"
check "regression body points at the acceptance evidence" \
  sh -c 'grep -Fq "Kind: regression" "$1" && grep -Fq "gate.json" "$1"' sh "$CREATED/1.body"
check "regression issue re-enters the scheduling queue" \
  sh -c 'grep -q "ready-for-agent" "$1"' sh "$CREATED/1.labels"
restore_fixture

# ============================================================================
echo "== AC3: remediation reruns are deduplicated =="

reset_scenario
gap_findings G001 REQ2 missing "Signed export artifact is not implemented"
printf '21\t[%s/G001] Signed export artifact is not implemented (attempt 1)\tCLOSED\n' "$FEATURE" >> "$ISSUES_TSV"
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl" --budget 2 --json
check "recurring gap after a closed attempt opens the next attempt" \
  sh -c '[ "$(cat "$1")" = 1 ] && grep -Fq "(attempt 2)" "$2"' \
  sh "$COUNTER" "$CREATED/1.title"
check "rerun reports the attempt count in the summary" \
  sh -c 'grep -Fq "\"created\":[\"016-demo/G001\"]" "$1"' sh "$OUT_FILE"
restore_fixture

reset_scenario
printf '21\t[%s/G001] Signed export artifact is not implemented (attempt 1)\tOPEN\n' "$FEATURE" >> "$ISSUES_TSV"
printf '21\t[%s/G001] Signed export artifact is not implemented (attempt 1)\tOPEN\n' "$FEATURE" > "$OPEN_TSV"
gap_findings G001 REQ2 missing "Signed export artifact is not implemented"
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl" --json
check "open remediation work keeps the queue undrained instead of duplicating" \
  sh -c '[ "$1" = 3 ] && [ ! -s "$2" ]' sh "$STATUS" "$COUNTER"
restore_fixture

# ============================================================================
echo "== AC4: finite budget reports non-converging work as blocked =="

reset_scenario
gap_findings G001 REQ2 missing "Signed export artifact is not implemented"
printf '21\t[%s/G001] Signed export artifact is not implemented (attempt 1)\tCLOSED\n' "$FEATURE" >> "$ISSUES_TSV"
printf '22\t[%s/G001] Signed export artifact is not implemented (attempt 2)\tCLOSED\n' "$FEATURE" >> "$ISSUES_TSV"
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl" --budget 2 --json
check "exhausted convergence budget exits as blocked" \
  sh -c '[ "$1" = 4 ]' sh "$STATUS"
check "json reports the blocked identity" \
  sh -c 'grep -Fq "\"status\":\"blocked\"" "$1" && grep -Fq "\"blocked\":[\"016-demo/G001\"]" "$1"' sh "$OUT_FILE"
check "blocked report is a blocked-labeled issue, not scheduled work" \
  sh -c '[ "$(cat "$1")" = 1 ] && grep -q "blocked" "$2" && ! grep -q "ready-for-agent" "$2"' \
  sh "$COUNTER" "$CREATED/1.labels"
check "blocked body is actionable: budget and requirement" \
  sh -c 'grep -qi "budget" "$1" && grep -Fq "Requirement: REQ2" "$1"' sh "$CREATED/1.body"
check "no completion is published for non-converging work" \
  sh -c '! grep -q -- "-X PATCH" "$1" && ! test -f "$2"' sh "$GH_LOG" "$FX/specs/$FEATURE/convergence/complete.json"

printf '23\t[%s/G001] Signed export artifact is not implemented (blocked)\tOPEN\n' "$FEATURE" >> "$ISSUES_TSV"
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl" --budget 2 --json
check "blocked report is deduplicated on rerun" \
  sh -c '[ "$(cat "$1")" = 1 ] && [ "$2" = 4 ]' sh "$COUNTER" "$STATUS"
restore_fixture

reset_scenario
gap_findings G001 REQ999 missing "Requirement never approved"
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl" --json
check "finding outside the approved scope never becomes scheduled work" \
  sh -c '[ "$1" = 4 ] && grep -q "blocked" "$2" && ! grep -q "ready-for-agent" "$2"' \
  sh "$STATUS" "$CREATED/1.labels"
check "out-of-scope body asks for a human scope decision" \
  sh -c 'grep -qi "outside" "$1" && grep -qi "re-approv" "$1"' sh "$CREATED/1.body"
restore_fixture

# ============================================================================
echo "== AC5: true completion publishes status with traceability =="

reset_scenario
cat > "$FX/specs/$FEATURE/findings.jsonl" <<'EOF'
{"id": "V001", "requirement": "REQ1", "kind": "verified", "summary": "End-to-end flow checked", "evidence": "tests/e2e flow passes on target branch"}
{"id": "V002", "requirement": "REQ2", "kind": "verified", "summary": "Signed export checked", "evidence": "tests/export signed artifact asserted"}
EOF
BEFORE=$(immutable_hashes)
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl" --json
check "no gaps and passing acceptance complete the project" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"complete\"" "$2"' sh "$STATUS" "$OUT_FILE"
COMPLETE="$FX/specs/$FEATURE/convergence/complete.json"
check "completion record maps every requirement to evidence" \
  sh -c 'grep -Fq "\"id\": \"REQ1\"" "$1" && grep -Fq "\"id\": \"REQ3\"" "$1"' sh "$COMPLETE"
check "verified requirements cite the converge evidence" \
  sh -c 'grep -Fq "\"status\": \"verified\"" "$1" && grep -Fq "tests/export signed artifact asserted" "$1"' sh "$COMPLETE"
check "unverifiable requirements fall back to acceptance evidence" \
  sh -c 'grep -Fq "\"status\": \"integrated-acceptance\"" "$1" && grep -Fq "convergence/evidence/gate.json" "$1"' sh "$COMPLETE"
check "completion closes the feature milestone" \
  sh -c 'grep -q -- "-X PATCH" "$1" && grep -Fq "milestones/3" "$1"' sh "$GH_LOG"
check "completion runs the integrated acceptance" test -s "$GATE_LOG"
check "approved spec, plan, tasks and approval record stay immutable" \
  sh -c '[ "$1" = "$2" ]' sh "$BEFORE" "$(immutable_hashes)"

run_sc "specs/$FEATURE/spec.md" "$R1"
check "human output announces PROJECT-COMPLETE" \
  sh -c 'grep -q "PROJECT-COMPLETE" "$1"' sh "$OUT_FILE"
restore_fixture

reset_scenario
printf '1\n' > "$GATE_RC"
cat > "$FX/specs/$FEATURE/findings.jsonl" <<'EOF'
{"id": "V001", "requirement": "REQ1", "kind": "verified", "summary": "End-to-end flow checked", "evidence": "tests/e2e flow passes on target branch"}
EOF
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl" --json
check "verified findings cannot outweigh a failing acceptance" \
  sh -c '[ "$1" = 0 ] && grep -Fq "\"status\":\"remediation-scheduled\"" "$2"' sh "$STATUS" "$OUT_FILE"
check "no completion record when acceptance fails" \
  test ! -f "$FX/specs/$FEATURE/convergence/complete.json"
restore_fixture

# ============================================================================
echo "== findings contract and malformed input =="

reset_scenario
printf '{"id": "G001", "requirement": "REQ2", "kind": "wat", "summary": "x", "evidence": "y"}\n' \
  > "$FX/specs/$FEATURE/findings.jsonl"
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl"
check "unknown finding kind is rejected with an actionable error" \
  sh -c '[ "$1" != 0 ] && grep -q "kind" "$2"' sh "$STATUS" "$OUT_ERR"
restore_fixture

reset_scenario
cat > "$FX/specs/$FEATURE/findings.jsonl" <<'EOF'
{"id": "G001", "requirement": "REQ2", "kind": "missing", "summary": "x", "evidence": "y"}
{"id": "G001", "requirement": "REQ3", "kind": "missing", "summary": "x2", "evidence": "y2"}
EOF
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl"
check "duplicate finding ids are rejected" \
  sh -c '[ "$1" != 0 ] && grep -qi "duplicate" "$2"' sh "$STATUS" "$OUT_ERR"
restore_fixture

reset_scenario
printf '{"id": "V001", "requirement": "REQ999", "kind": "verified", "summary": "x", "evidence": "y"}\n' \
  > "$FX/specs/$FEATURE/findings.jsonl"
run_sc "specs/$FEATURE/spec.md" "$R1" --findings "specs/$FEATURE/findings.jsonl"
check "verified entry for an unknown requirement is rejected" \
  sh -c '[ "$1" != 0 ]' sh "$STATUS"
restore_fixture

reset_scenario
run_sc "specs/$FEATURE/spec.md" "$R1" --budget 0
check "non-positive budget is a usage error" sh -c '[ "$1" = 2 ]' sh "$STATUS"

# ============================================================================
echo "== wiring: workflow, roles, docs =="

WF="$REPO_ROOT/.github/workflows/spec-converge.yml"
check "spec-converge workflow exists" test -f "$WF"
if [ -f "$WF" ]; then
  check "workflow is human-triggered with spec and revision inputs" \
    sh -c 'grep -q "workflow_dispatch" "$1" && grep -q "spec:" "$1" && grep -q "revision:" "$1"' sh "$WF"
  check "workflow prefights the implement role" \
    sh -c 'grep -q "agent-preflight.sh verify implement" "$1"' sh "$WF"
  check "precheck step delegates to the outcome adapter with an id" \
    sh -c 'grep -q "id: precheck" "$1" && grep -q "scripts/spec-converge-precheck.sh" "$1" && grep -q -- "--precheck" "$1"' sh "$WF"
  check "agent evaluation only runs on a ready precheck outcome" \
    sh -c 'grep -B2 "scripts/agent.sh" "$1" | grep -q "steps.precheck.outputs.outcome" ' sh "$WF"
  check "remediation and publication only run on a ready precheck outcome" \
    sh -c '[ "$(grep -c "steps.precheck.outputs.outcome == .ready." "$1")" -ge 2 ]' sh "$WF"
  check "undrained queue no longer bypasses step gating via a bare exit 0" \
    sh -c '! grep -Fq "exit 0" "$1"' sh "$WF"
  check "workflow runs the converge skill via the shared dispatcher" \
    sh -c 'grep -q "speckit-converge" "$1" && grep -q "scripts/agent.sh" "$1"' sh "$WF"
  check "workflow verifies completion via the entrypoint" \
    sh -c 'grep -q "scripts/spec-converge.sh" "$1" && grep -q -- "--findings" "$1"' sh "$WF"
  check "workflow fetches full history so the revision resolves" \
    sh -c 'grep -q "fetch-depth: 0" "$1"' sh "$WF"
  check "workflow uploads findings and evidence artifacts" \
    sh -c 'grep -q "findings.jsonl" "$1" && grep -q "evidence" "$1"' sh "$WF"
fi

check "implement role maps the converge skill" \
  sh -c 'sed -n "/^    \"implement\": {/,/^    }/p" "$1" | grep -q "speckit-converge"' \
  sh "$REPO_ROOT/.agent/roles.json"

DOC="$REPO_ROOT/docs/SPEC_CONVERGE.md"
check "convergence doc exists" test -f "$DOC"
if [ -f "$DOC" ]; then
  check "doc defines the findings schema" \
    sh -c 'grep -q "findings.jsonl" "$1" && grep -q "verified" "$1"' sh "$DOC"
  check "doc defines the convergence budget and blocked semantics" \
    sh -c 'grep -qi "budget" "$1" && grep -qi "blocked" "$1"' sh "$DOC"
  check "doc preserves the approved spec and plan" \
    sh -c 'grep -q "绝不修改" "$1"' sh "$DOC"
fi
check "AGENTS.md points at the convergence entrypoint documentation" \
  sh -c 'grep -q "docs/SPEC_CONVERGE.md" "$1"' sh "$REPO_ROOT/AGENTS.md"

check "entrypoint shells out to gh and the shared gate, never to an MCP server" \
  sh -c 'grep -q "gh issue list" "$1" && grep -q "ci-gate.sh" "$1" && ! grep -qi "mcp" "$1"' \
  sh "$REPO_ROOT/scripts/spec-converge.sh"

check "precheck adapter exists and reuses the entrypoint, never gh or the gate" \
  sh -c 'test -f "$1" && grep -q "spec-converge.sh" "$1" && ! grep -q "gh " "$1" && ! grep -q "ci-gate" "$1"' \
  sh "$REPO_ROOT/scripts/spec-converge-precheck.sh"
check "precheck adapter maps all three outcomes explicitly" \
  sh -c 'grep -q "ready" "$1" && grep -q "deferred" "$1" && grep -q "failed" "$1"' \
  sh "$REPO_ROOT/scripts/spec-converge-precheck.sh"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
