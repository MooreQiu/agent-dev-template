#!/usr/bin/env bash
# Acceptance tests for issue #16: start autonomous planning and issue
# generation from an approved specification.
#
# Covers (issue #16 acceptance criteria):
#   AC1 explicit start entrypoint with human-approved spec path and immutable
#       revision; never silently replace approved requirements (missing
#       approval, revision mismatch, stale revision, revision without spec)
#   AC2 plan/tasks validated after approval; specification role wiring
#       (missing plan.md / tasks.md -> unmet planning prerequisites; roles.json
#       maps the planning skills; the Actions workflow prefights the role)
#   AC3 decision policy documented: autonomous within approved constraints,
#       genuinely unresolved requirements become blocked, not CI questions
#   AC4 actionable issues: acceptance criteria, spec references, milestone,
#       dependencies, scheduling eligibility (ready-for-agent label)
#   AC5 feature/spec-qualified task identities; idempotent dedup including
#       closed issues; T001 in different features never collides
#   AC6 plain gh APIs only (no GitHub MCP assumption)
#   AC7 the tests themselves
#
# Run: bash tests/test-spec-start.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-spec-start.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

GH_LOG="$TMP/gh.log"
MOCK_BIN="$TMP/bin"
CREATED="$TMP/created"
COUNTER="$TMP/counter"
ISSUES_TSV="$TMP/issues.tsv"
mkdir -p "$MOCK_BIN" "$CREATED"
: > "$ISSUES_TSV"

failures=0
ok()   { echo "ok - $1"; }
bad()  { echo "FAIL - $1"; failures=$((failures + 1)); }

check() { # check <description> <command...>
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

artifact_path_entries() { # artifact_path_entries <workflow> -> path block entries
  # Prints the entries of the upload step's "path: |" block. upload-artifact
  # (@actions/glob) rejects patterns containing "." or ".." segments, so the
  # entries must be traversal-free.
  awk '
    /^ *path: \|/ { inp=1; indent=index($0, "path:") - 1; next }
    inp {
      if ($0 ~ /^ *$/) next
      stripped=$0
      sub(/^ +/, "", stripped)
      if (length($0) - length(stripped) <= indent) exit
      print stripped
    }
  ' "$1"
}

# --- mocked gh (records every call; serves issue list from a TSV fixture) ---
cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
if [ "$1" = repo ] && [ "$2" = view ]; then echo "acme/fixture"; exit 0; fi
if [ "$1" = api ]; then exit 0; fi
if [ "$1" = issue ] && [ "$2" = list ]; then cat "$ISSUES_TSV"; exit 0; fi
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
export GH_LOG ISSUES_TSV COUNTER CREATED

FEATURE="016-demo"

# --- fixture repository with an approved feature ----------------------------
# History: R0 (empty) -> R1 (spec.md approved) -> R2 (approval + plan + tasks)
make_fixture() { # make_fixture <dir>
  fx=$1
  mkdir -p "$fx/scripts" "$fx/specs/$FEATURE"
  cp "$REPO_ROOT/scripts/spec-start.sh" "$fx/scripts/spec-start.sh" 2>/dev/null
  git -C "$fx" init -q
  git -C "$fx" -c user.name=Test -c user.email=test@example.com \
    commit -q --allow-empty -m "init"
  cat > "$fx/specs/$FEATURE/spec.md" <<EOSPEC
# Spec: $FEATURE

## Requirement
- REQ1 The feature works end to end.
EOSPEC
  git -C "$fx" add -A
  git -C "$fx" -c user.name=Test -c user.email=test@example.com commit -qm "spec"
  R1=$(git -C "$fx" rev-parse HEAD)
  printf '%s\n' "$R1" > "$fx/.approved"
  write_approval "$fx" "$R1"
  cat > "$fx/specs/$FEATURE/plan.md" <<'EOPLAN'
# Plan: 016-demo
Approach derived from the approved spec.
EOPLAN
  cat > "$fx/specs/$FEATURE/tasks.md" <<'EOTASK'
# Tasks: 016-demo

## Phase 1
- [ ] T001 Create project structure per implementation plan
- [ ] T002 [P] Configure linting and formatting tools
- [ ] T003 Implement service in src/services/ (depends on T001, T002)
- [ ] T004 Harden deployment (depends on T999)
- [x] T005 Scaffold already completed
EOTASK
  git -C "$fx" add -A
  git -C "$fx" -c user.name=Test -c user.email=test@example.com commit -qm "artifacts"
}

write_approval() { # write_approval <dir> <revision> [approved_by]
  fx=$1 rev=$2 by=${3-tester}
  cat > "$fx/specs/$FEATURE/approval.json" <<EOAPP
{
  "spec": "specs/$FEATURE/spec.md",
  "revision": "$rev",
  "approved_by": "$by",
  "approved_at": "2026-10-09T00:00:00Z"
}
EOAPP
}

FX="$TMP/repo"
make_fixture "$FX"
SS="$FX/scripts/spec-start.sh"
R0=$(git -C "$FX" rev-parse HEAD~2)
R1=$(cat "$FX/.approved")

OUT_ERR="$TMP/err.txt"
OUT_FILE="$TMP/out.txt"

run_ss() { # run_ss [args...] -> $STATUS / $OUT_FILE / $OUT_ERR
  : > "$GH_LOG"
  OUT=$(cd "$FX" && PATH="$MOCK_BIN:$PATH" bash "$SS" "$@" 2>"$OUT_ERR")
  STATUS=$?
  printf '%s\n' "$OUT" > "$OUT_FILE"
}

reset_scenario() { # clean mock state between scenarios
  rm -rf "$CREATED"; mkdir -p "$CREATED"
  rm -f "$COUNTER"
  : > "$ISSUES_TSV"
}

restore_fixture() { # restore_fixture -- reset fixture files to approved state
  git -C "$FX" checkout -- "specs/$FEATURE" 2>/dev/null
  write_approval "$FX" "$R1"
}

# ============================================================================
echo "== AC1: explicit entrypoint, approval and immutable revision =="

run_ss
check "no arguments prints usage and exits 2" \
  sh -c '[ "$1" = 2 ] && grep -q "Usage" "$2"' sh "$STATUS" "$OUT_ERR"

run_ss "specs/$FEATURE/spec.md" "$R1" --dry-run
check "approved spec passes the gates in dry-run" \
  sh -c '[ "$1" = 0 ]' sh "$STATUS"

check "dry-run never calls gh" test ! -s "$GH_LOG"

rm "$FX/specs/$FEATURE/approval.json"
OUT2=$(cd "$FX" && PATH="$MOCK_BIN:$PATH" bash "$SS" "specs/$FEATURE/spec.md" "$R1" 2>"$OUT_ERR"); S2=$?
check "missing approval record fails with actionable error" \
  sh -c '[ "$1" != 0 ] && grep -q "approval" "$2"' sh "$S2" "$OUT_ERR"
restore_fixture

write_approval "$FX" "$R0"
run_ss "specs/$FEATURE/spec.md" "$R1"
check "approval revision mismatch is rejected" \
  sh -c '[ "$1" != 0 ] && grep -qi "mismatch" "$2"' sh "$STATUS" "$OUT_ERR"
restore_fixture

write_approval "$FX" "$R1" ""
run_ss "specs/$FEATURE/spec.md" "$R1"
check "approval without an approver is rejected" \
  sh -c '[ "$1" != 0 ] && grep -q "approved_by" "$2"' sh "$STATUS" "$OUT_ERR"
restore_fixture

write_approval "$FX" "$R0"
run_ss "specs/$FEATURE/spec.md" "$R0"
check "revision that predates the spec is rejected" \
  sh -c '[ "$1" != 0 ] && grep -q "does not contain" "$2"' sh "$STATUS" "$OUT_ERR"
restore_fixture

printf '\n## Requirement\n- REQ2 Sneaked in after approval.\n' \
  >> "$FX/specs/$FEATURE/spec.md"
run_ss "specs/$FEATURE/spec.md" "$R1"
check "spec edited after approval is stale, never silently replaced" \
  sh -c '[ "$1" != 0 ] && grep -qi "stale" "$2"' sh "$STATUS" "$OUT_ERR"
restore_fixture

run_ss "specs/../etc/passwd" "$R1"
check "spec paths outside the repository are rejected" \
  sh -c '[ "$1" != 0 ]' sh "$STATUS"

# ============================================================================
echo "== AC2: plan/tasks prerequisites and specification role =="

rm "$FX/specs/$FEATURE/plan.md"
run_ss "specs/$FEATURE/spec.md" "$R1"
check "missing plan.md reports unmet planning prerequisites" \
  sh -c '[ "$1" = 3 ] && grep -q "plan.md" "$2"' sh "$STATUS" "$OUT_ERR"
check "prerequisite error points at the planning stage skills" \
  sh -c 'grep -q "speckit-plan" "$1" && grep -q "speckit-tasks" "$1"' sh "$OUT_ERR"
restore_fixture

rm "$FX/specs/$FEATURE/tasks.md"
run_ss "specs/$FEATURE/spec.md" "$R1"
check "missing tasks.md reports unmet planning prerequisites" \
  sh -c '[ "$1" = 3 ] && grep -q "tasks.md" "$2"' sh "$STATUS" "$OUT_ERR"
restore_fixture

check "specification role maps the planning skills" \
  sh -c 'sed -n "/^    \"specify\": {/,/^    }/p" "$1" | grep -q "speckit-plan" && sed -n "/^    \"specify\": {/,/^    }/p" "$1" | grep -q "speckit-tasks"' \
  sh "$REPO_ROOT/.agent/roles.json"

WF="$REPO_ROOT/.github/workflows/spec-start.yml"
check "spec-start workflow exists" test -f "$WF"
if [ -f "$WF" ]; then
  check "workflow is human-triggered with spec and revision inputs" \
    sh -c 'grep -q "workflow_dispatch" "$1" && grep -q "spec:" "$1" && grep -q "revision:" "$1"' sh "$WF"
  check "workflow prefights the specification role" \
    sh -c 'grep -q "agent-preflight.sh verify specify" "$1"' sh "$WF"
  check "workflow plans autonomously when prerequisites are unmet" \
    sh -c 'grep -q "PLANNING_REQUIRED" "$1" && grep -q "speckit-plan" "$1"' sh "$WF"
  check "workflow generates issues via the entrypoint" \
    sh -c 'grep -q "scripts/spec-start.sh" "$1"' sh "$WF"
  check "workflow fetches full history so the revision resolves" \
    sh -c 'grep -q "fetch-depth: 0" "$1"' sh "$WF"

  ARTIFACT_PATHS="$TMP/artifact-paths.txt"
  artifact_path_entries "$WF" > "$ARTIFACT_PATHS"
  check "workflow uploads the plan and tasks artifacts with a binding manifest" \
    sh -c 'grep -q "manifest\.json" "$1" && grep -q "plan\.md" "$1" && grep -q "tasks\.md" "$1"' \
    sh "$ARTIFACT_PATHS"
  check "bundles never carry the approved spec itself (git is its store)" \
    sh -c '! grep -q "spec\.md" "$1"' sh "$ARTIFACT_PATHS"
  check "artifact upload paths contain no .. segment" \
    sh -c '! grep -q "\.\." "$1"' sh "$ARTIFACT_PATHS"
  check "artifact paths derive the feature dir from the spec path" \
    sh -c 'grep -Fq "FEATURE_DIR=\$(dirname" "$1" && grep -Fq "env.FEATURE_DIR" "$2"' \
    sh "$WF" "$ARTIFACT_PATHS"
fi

# ============================================================================
echo "== AC3: decision policy (autonomous within constraints, else blocked) =="

DOC="$REPO_ROOT/docs/SPEC_START.md"
check "decision policy is documented" \
  sh -c 'grep -q "autonomously within approved constraints" "$1" && grep -q "blocked instead of asking" "$1"' sh "$DOC"
check "policy document defines the approval record" \
  sh -c 'grep -q "approval.json" "$1"' sh "$DOC"
check "AGENTS.md points at the start entrypoint documentation" \
  sh -c 'grep -q "docs/SPEC_START.md" "$1"' sh "$REPO_ROOT/AGENTS.md"

# ============================================================================
echo "== AC4 + AC5: issue creation, format, deps, dedup =="

reset_scenario
run_ss "specs/$FEATURE/spec.md" "$R1"

check "run against the approved spec succeeds" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "creates one issue per unchecked task (4 of 5)" \
  sh -c '[ "$(cat "$1")" = 4 ]' sh "$COUNTER"

check "issue title uses the feature-qualified identity" \
  sh -c '[ "$(cat "$1")" = "[$2/T001] Create project structure per implementation plan" ]' \
  sh "$CREATED/1.title" "$FEATURE"
check "dependency clause is stripped from the title" \
  sh -c 'grep -vq "depends on" "$1"' sh "$CREATED/3.title"

check "body carries the acceptance criteria" \
  sh -c 'grep -q "## Acceptance criteria" "$1" && grep -Fq -- "- [ ] Implement service in src/services/" "$1"' \
  sh "$CREATED/3.body"
check "body references spec path and approved revision" \
  sh -c 'grep -Fq "Spec: specs/016-demo/spec.md" "$1" && grep -Fq "$2" "$1"' \
  sh "$CREATED/3.body" "$R1"
check "body records the task identity" \
  sh -c 'grep -Fq "Task identity: $2/T003" "$1"' sh "$CREATED/3.body" "$FEATURE"
check "body links dependency issues by number" \
  sh -c 'grep -Fq "Depends: #1 #2" "$1"' sh "$CREATED/3.body"
check "body notes the scheduling contract" \
  sh -c 'grep -q "ready-for-agent" "$1"' sh "$CREATED/3.body"

check "issues are labeled ready-for-agent" \
  sh -c 'grep -q "ready-for-agent" "$1" && grep -q "ready-for-agent" "$2"' \
  sh "$CREATED/1.labels" "$CREATED/3.labels"
check "issues join the feature milestone" \
  sh -c '[ "$(cat "$1")" = "016-demo" ] && [ "$(cat "$2")" = "016-demo" ]' \
  sh "$CREATED/1.milestone" "$CREATED/2.milestone"
check "milestone is ensured via the gh API" \
  sh -c 'grep -q "api repos/acme/fixture/milestones" "$1"' sh "$GH_LOG"

check "unresolved dependency blocks the task instead of asking" \
  sh -c 'grep -q "blocked" "$1" && ! grep -q "ready-for-agent" "$1"' sh "$CREATED/4.labels"
check "blocked issue documents the unresolved dependency" \
  sh -c 'grep -Fq "T999" "$1"' sh "$CREATED/4.body"

check "checked tasks are not converted" \
  sh -c 'grep -Fq "T005" "$1"' sh "$OUT_FILE"
check "human summary reports created and blocked" \
  sh -c 'grep -q "summary:" "$1" && grep -Fq "blocked 1" "$1"' sh "$OUT_FILE"

# --- structured output for the scheduler (#17) ------------------------------
reset_scenario
run_ss "specs/$FEATURE/spec.md" "$R1" --json
check "--json emits a single structured line" \
  sh -c '[ "$(wc -l < "$1" | tr -d " ")" = 1 ]' sh "$OUT_FILE"
check "--json reports created issue numbers" \
  sh -c 'grep -Fq "\"created\":[1,2,3,4]" "$1"' sh "$OUT_FILE"
check "--json reports skipped and blocked identities" \
  sh -c 'grep -Fq "\"skipped\":[\"016-demo/T005\"]" "$1" && grep -Fq "\"blocked\":[\"016-demo/T004\"]" "$1"' sh "$OUT_FILE"

# --- rerun is idempotent -----------------------------------------------------
reset_scenario
printf '7\t[%s/T001] Create project structure per implementation plan\n' "$FEATURE" > "$ISSUES_TSV"
printf '8\t[%s/T002] [P] Configure linting and formatting tools\n' "$FEATURE" >> "$ISSUES_TSV"
printf '9\t[%s/T003] Implement service in src/services/\n' "$FEATURE" >> "$ISSUES_TSV"
printf '10\t[%s/T004] Harden deployment\n' "$FEATURE" >> "$ISSUES_TSV"
run_ss "specs/$FEATURE/spec.md" "$R1"
check "rerun with existing issues creates nothing" \
  sh -c '! grep -q "issue create" "$1"' sh "$GH_LOG"
check "dedup lookup includes closed issues (state all)" \
  sh -c 'grep -q "issue list --state all" "$1"' sh "$GH_LOG"
check "rerun reports every task as skipped" \
  sh -c 'grep -Fq "T001" "$1" && grep -Fq "T004" "$1" && grep -Fq "created 0" "$1"' sh "$OUT_FILE"

# --- partial rerun resolves dependencies against existing issues -------------
reset_scenario
printf '7\t[%s/T001] Create project structure per implementation plan\n' "$FEATURE" > "$ISSUES_TSV"
run_ss "specs/$FEATURE/spec.md" "$R1"
check "existing task is skipped, the rest are created" \
  sh -c '[ "$(cat "$1")" = 3 ] && grep -Fq "T001" "$2"' sh "$COUNTER" "$OUT_FILE"
check "dependencies resolve to the pre-existing issue number" \
  sh -c 'grep -Fq "Depends: #7 #1" "$1"' sh "$CREATED/2.body"

# --- cross-feature identities never collide ---------------------------------
reset_scenario
printf '9\t[017-other/T001] Create project structure per implementation plan\n' > "$ISSUES_TSV"
run_ss "specs/$FEATURE/spec.md" "$R1"
check "T001 of another feature does not dedupe this feature's T001" \
  sh -c '[ "$(cat "$1")" = 4 ] && grep -Fq "[$3/T001]" "$2"' \
  sh "$COUNTER" "$CREATED/1.title" "$FEATURE"

# --- malformed task lists ----------------------------------------------------
reset_scenario
cat > "$FX/specs/$FEATURE/tasks.md" <<'EOTASK'
# Tasks: 016-demo
- [ ] T001 Create project structure per implementation plan
- [ ] T001 Duplicate task id must fail
EOTASK
run_ss "specs/$FEATURE/spec.md" "$R1"
check "duplicate task ids in tasks.md are rejected" \
  sh -c '[ "$1" != 0 ] && grep -qi "duplicate" "$2"' sh "$STATUS" "$OUT_ERR"
restore_fixture

printf '# Tasks: 016-demo\nNo checkboxes here.\n' > "$FX/specs/$FEATURE/tasks.md"
run_ss "specs/$FEATURE/spec.md" "$R1"
check "task list without tasks is rejected" \
  sh -c '[ "$1" != 0 ] && grep -qi "no tasks" "$2"' sh "$STATUS" "$OUT_ERR"
restore_fixture

# ============================================================================
echo "== AC6: plain gh APIs, no MCP assumption =="

check "entrypoint shells out to gh, never to a GitHub MCP server" \
  sh -c 'grep -q "gh issue list" "$1" && grep -q "gh issue create" "$1" && ! grep -qi "mcp" "$1"' \
  sh "$REPO_ROOT/scripts/spec-start.sh"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
