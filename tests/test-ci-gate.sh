#!/usr/bin/env bash
# Acceptance tests for issue #15: deterministic CI quality gates independent
# of agent claims.
#
# Covers:
#   - scripts/ci-gate.sh run executes the install/build/test/lint/typecheck
#     commands configured in .agent/project.json, records a machine-verifiable
#     evidence artifact (gate.json + per-command logs), and fails the gate on
#     nonzero exits (AC1)
#   - scripts/ci-gate.sh check rejects missing evidence, absent or skipped
#     required checks, non-green records and logs that were not captured;
#     complete green evidence is accepted (AC1, AC5)
#   - test-first evidence: a code change must keep a commit in the reviewed
#     range where the configured test suite is red before HEAD turns green;
#     implementation-before-tests, code-without-tests and fabricated SHAs are
#     rejected; docs-only ranges skip the requirement (AC3)
#   - stable check names: workflow "CI Gate" / job "quality-gate" runs the
#     gate on every pull request, setup.sh registers the context as a
#     required status check, and pr-review.yml enforces the same gate before
#     the auto-merge decider (AC2, AC4)
#   - the merge controller (scripts/review-verdict.sh) consults the gate:
#     with CI_GATE_EVIDENCE set it merges only on accepted evidence; with the
#     variable unset it keeps the previous behavior (AC4)
#
# Run: bash tests/test-ci-gate.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="scripts/ci-gate.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/adt-ci-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
ok()   { echo "ok - $1"; }
bad()  { echo "FAIL - $1${2:+ -- $2}"; failures=$((failures + 1)); }

check() { # check <description> <command...>
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

RC="$WORK/rc"
OUT="$WORK/out"

run_gate() { # run_gate <fixture-dir> [args...] -> rc in $RC, output in $OUT
  d="$1"; shift
  bash "$d/$GATE" "$@" > "$OUT" 2>&1
  echo $? > "$RC"
}

rc0()     { [ "$(cat "$RC")" -eq 0 ]; }
rc_bad()  { [ "$(cat "$RC")" -ne 0 ]; }
out_grep() { grep -Eq "$1" "$OUT"; }

expect() { # expect <description> ok|bad <pattern> -- rc and output assertion
  desc=$1; want=$2; pat=$3
  if [ "$want" = ok ]; then
    if rc0 && out_grep "$pat"; then ok "$desc"; else bad "$desc" "exit $(cat "$RC")"; fi
  else
    if rc_bad && out_grep "$pat"; then ok "$desc"; else bad "$desc" "exit $(cat "$RC")"; fi
  fi
}

# --- fixture repositories ----------------------------------------------------

fixture_commit() { # fixture_commit <dir> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name=Test -c user.email=test@example.com commit -qm "$2"
}

fixture_head() { git -C "$1" rev-parse HEAD; }

make_project() { # make_project <name> -- repo with configured commands
  d="$WORK/$1"
  mkdir -p "$d/scripts" "$d/bin" "$d/.agent" "$d/tests"
  cp "$REPO_ROOT/$GATE" "$d/$GATE"
  for c in install build lint typecheck; do
    printf '#!/usr/bin/env bash\necho "%s ok"\n' "$c" > "$d/bin/$c.sh"
  done
  cat > "$d/tests/run-all.sh" <<'RUNNER'
#!/bin/sh
set -u
cd "$(dirname "$0")/.."
status=0
for t in tests/test*.sh; do
  [ -e "$t" ] || continue
  bash "$t" || status=1
done
exit "$status"
RUNNER
  cat > "$d/.agent/project.json" <<'CFG'
{
  "commands": {
    "install": "bash bin/install.sh",
    "build": "bash bin/build.sh",
    "test": "bash tests/run-all.sh",
    "lint": "bash bin/lint.sh",
    "typecheck": "bash bin/typecheck.sh"
  }
}
CFG
  git -C "$d" init -q
  fixture_commit "$d" "baseline"
}

# --- run mode: successful validation (AC1, AC5) ------------------------------

echo "== run: successful validation"

make_project green
EV="$WORK/ev-green"
BASE="$(fixture_head "$WORK/green")"
run_gate "$WORK/green" run --evidence-dir "$EV" --base "$BASE"
expect "green run passes the gate" ok 'gate: passed'
check "evidence records the configured test command" \
  grep -Fq '"command": "bash tests/run-all.sh"' "$EV/gate.json"
check "all five configured commands recorded" \
  sh -c 'for n in install build test lint typecheck; do grep -Fq "\"name\": \"$n\"" "$1/gate.json" || exit 1; done' sh "$EV"
check "every recorded command exited 0" \
  sh -c '! grep -Eq "\"exit\": [1-9]" "$1/gate.json"' sh "$EV"
check "per-command logs captured" \
  sh -c 'for n in install build test lint typecheck; do [ -s "$1/$n.log" ] || exit 1; done' sh "$EV"
check "unchanged range records no-code-change evidence" \
  grep -Fq '"status": "no-code-change"' "$EV/test-first.json"

run_gate "$WORK/green" check --evidence-dir "$EV"
expect "check accepts complete green evidence" ok 'gate-check: passed'

# --- run mode: failing command fails the gate (AC1, AC5) ---------------------

echo "== run: failing command"

make_project broken
printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n' > "$WORK/broken/tests/test-broken.sh"
BASE="$(fixture_head "$WORK/broken")"
fixture_commit "$WORK/broken" "red: add failing test"
EV="$WORK/ev-broken"
run_gate "$WORK/broken" run --evidence-dir "$EV" --base "$BASE"
expect "nonzero test exit fails the run gate" bad 'gate: FAIL test exited 1'
check "failure recorded with its exit code" grep -Fq '"exit": 1' "$EV/gate.json"
check "failing output captured in the evidence log" grep -Fq boom "$EV/test.log"

run_gate "$WORK/broken" check --evidence-dir "$EV"
expect "check rejects a nonzero test record" bad "required check 'test'"

# --- check mode: missing evidence, skipped required checks (AC5) -------------

echo "== check: missing evidence and skipped checks"

EV="$WORK/ev-empty"
mkdir -p "$EV"
run_gate "$WORK/green" check --evidence-dir "$EV"
expect "empty evidence dir is rejected" bad 'gate\.json'

cp -R "$WORK/ev-green" "$WORK/ev-nolog"
rm "$WORK/ev-nolog/test.log"
run_gate "$WORK/green" check --evidence-dir "$WORK/ev-nolog"
expect "record without a captured log is rejected" bad 'test\.log'

cp -R "$WORK/ev-green" "$WORK/ev-nolint"
sed '/"name": "lint"/d' "$WORK/ev-green/gate.json" > "$WORK/ev-nolint/gate.json"
run_gate "$WORK/green" check --evidence-dir "$WORK/ev-nolint"
expect "missing required check record is rejected" bad 'lint'

cp -R "$WORK/ev-green" "$WORK/ev-skipped"
sed 's/"exit": 0, "log": "test.log"/"status": "skipped"/' \
  "$WORK/ev-green/gate.json" > "$WORK/ev-skipped/gate.json"
run_gate "$WORK/green" check --evidence-dir "$WORK/ev-skipped"
expect "skipped required check is rejected" bad 'skipped'

rm "$WORK/ev-green/test-first.json"
run_gate "$WORK/green" check --evidence-dir "$WORK/ev-green"
expect "missing test-first evidence is rejected" bad 'test-first\.json'

# --- test-first evidence (AC3) -----------------------------------------------

echo "== test-first: red-to-green verified"

make_project tf
BASE="$(fixture_head "$WORK/tf")"
cat > "$WORK/tf/tests/test-hello.sh" <<'EOF'
#!/usr/bin/env bash
if [ -x scripts/hello.sh ]; then echo "hello ok"; else echo "hello missing"; exit 1; fi
EOF
fixture_commit "$WORK/tf" "red: failing tests for hello"
RED_SHA="$(fixture_head "$WORK/tf")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/tf/scripts/hello.sh"
chmod +x "$WORK/tf/scripts/hello.sh"
fixture_commit "$WORK/tf" "green: implement hello"
EV="$WORK/ev-tf"
run_gate "$WORK/tf" run --evidence-dir "$EV" --base "$BASE"
expect "red-then-green history passes the gate" ok 'gate: passed'
check "verified red-to-green evidence recorded" \
  grep -Fq '"status": "verified"' "$EV/test-first.json"
check "red commit identified in the evidence" \
  grep -Fq "\"red_commit\": \"$RED_SHA\"" "$EV/test-first.json"
check "nonzero red suite exit recorded" \
  grep -Eq '"red_suite_exit": [1-9]' "$EV/test-first.json"

run_gate "$WORK/tf" check --evidence-dir "$EV"
expect "check accepts verified red-to-green evidence" ok 'gate-check: passed'

echo "== test-first: implementation before tests"

make_project ta
BASE="$(fixture_head "$WORK/ta")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/ta/scripts/hello.sh"
chmod +x "$WORK/ta/scripts/hello.sh"
fixture_commit "$WORK/ta" "implementation first"
cat > "$WORK/ta/tests/test-hello.sh" <<'EOF'
#!/usr/bin/env bash
[ -x scripts/hello.sh ] || { echo "hello missing"; exit 1; }
echo "hello ok"
EOF
fixture_commit "$WORK/ta" "tests afterwards"
EV="$WORK/ev-ta"
run_gate "$WORK/ta" run --evidence-dir "$EV" --base "$BASE"
expect "test-after history fails the gate" bad 'no-red-commit'
check "failure status recorded" grep -Fq '"status": "failed"' "$EV/test-first.json"

echo "== test-first: code change without tests"

make_project cw
BASE="$(fixture_head "$WORK/cw")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/cw/scripts/hello.sh"
chmod +x "$WORK/cw/scripts/hello.sh"
fixture_commit "$WORK/cw" "code only"
EV="$WORK/ev-cw"
run_gate "$WORK/cw" run --evidence-dir "$EV" --base "$BASE"
expect "code change without tests fails the gate" bad 'code-change-without-tests'

echo "== test-first: docs-only change skips the requirement"

make_project docs
BASE="$(fixture_head "$WORK/docs")"
printf '# Notes\n' > "$WORK/docs/NOTES.md"
fixture_commit "$WORK/docs" "docs only"
EV="$WORK/ev-docs"
run_gate "$WORK/docs" run --evidence-dir "$EV" --base "$BASE"
expect "docs-only change passes the gate" ok 'gate: passed'
check "docs-only range records no-code-change" \
  grep -Fq '"status": "no-code-change"' "$EV/test-first.json"

echo "== test-first: unbased runs are not merge evidence"

make_project nb
EV="$WORK/ev-nb"
run_gate "$WORK/nb" run --evidence-dir "$EV"
expect "run without a base still gates the commands" ok 'gate: passed'
check "unbased run records the limitation" \
  grep -Fq '"status": "no-base"' "$EV/test-first.json"
run_gate "$WORK/nb" check --evidence-dir "$EV"
expect "check rejects no-base test-first evidence" bad 'no-base'

echo "== test-first: fabricated evidence is rejected"

cp -R "$WORK/ev-tf" "$WORK/ev-fake"
sed 's/"red_commit": "[0-9a-f]*"/"red_commit": "0000000000000000000000000000000000000000"/' \
  "$WORK/ev-tf/test-first.json" > "$WORK/ev-fake/test-first.json"
run_gate "$WORK/tf" check --evidence-dir "$WORK/ev-fake"
expect "check rejects a red_commit outside the repository" bad 'red_commit'

# --- merge controller consults the gate (AC4) --------------------------------

echo "== merge controller enforcement"

MOCK_BIN="$WORK/mock-bin"
mkdir -p "$MOCK_BIN"
GH_LOG="$WORK/gh.log"
export GH_LOG
cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
for a in "$@"; do
  case "$a" in
    repos/*/issues/*/comments)
      cat "$COMMENTS_FIXTURE"
      exit 0
      ;;
  esac
done
case "$1 $2" in
  "pr merge"|"pr edit"|"repo view") exit 0 ;;
esac
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"

cat > "$WORK/approve.json" <<'EOF'
[{"id": 1, "user": {"login": "github-actions[bot]"}, "body": "VERDICT: APPROVE - all acceptance tests verified green"}]
EOF
export COMMENTS_FIXTURE="$WORK/approve.json"

GOOD_EV="$WORK/ev-merge-ok"
mkdir -p "$GOOD_EV"
cat > "$GOOD_EV/gate.json" <<'EOF'
{
  "checks": [
    {"name": "install", "command": "npm install", "exit": 0, "log": "install.log"},
    {"name": "test", "command": "npm test", "exit": 0, "log": "test.log"}
  ]
}
EOF
printf 'install ok\n' > "$GOOD_EV/install.log"
printf 'tests ok\n' > "$GOOD_EV/test.log"
printf '{"status": "verified", "base": "n/a", "head": "n/a", "red_commit": "%s", "red_suite_exit": 1, "log": "test-first.log"}\n' \
  "$(git -C "$REPO_ROOT" rev-parse HEAD)" > "$GOOD_EV/test-first.json"
printf 'red run output\n' > "$GOOD_EV/test-first.log"

mkdir -p "$WORK/ev-merge-empty"

verdict_run() { # verdict_run <evidence-dir|->
  : > "$GH_LOG"
  if [ "$1" = "-" ]; then
    VOUT="$(env -u CI_GATE_EVIDENCE PATH="$MOCK_BIN:$PATH" GITHUB_REPOSITORY=acme/fixture \
      bash "$REPO_ROOT/scripts/review-verdict.sh" 42 2>"$WORK/verdict.err")"
    vrc=$?
  else
    VOUT="$(CI_GATE_EVIDENCE="$1" PATH="$MOCK_BIN:$PATH" GITHUB_REPOSITORY=acme/fixture \
      bash "$REPO_ROOT/scripts/review-verdict.sh" 42 2>"$WORK/verdict.err")"
    vrc=$?
  fi
}

verdict_run "$GOOD_EV"
check "accepted evidence lets an APPROVE verdict merge" \
  sh -c '[ "$1" -eq 0 ] && grep -q "pr merge 42" "$2"' sh "$vrc" "$GH_LOG"

verdict_run "$WORK/ev-merge-empty"
check "rejected evidence blocks the merge" \
  sh -c '[ "$1" -ne 0 ] && ! grep -Eq "pr (merge|edit)" "$2"' sh "$vrc" "$GH_LOG"
check "rejection explains the gate failure" \
  grep -Eq 'gate' "$WORK/verdict.err"

verdict_run -
check "unset CI_GATE_EVIDENCE keeps the previous merge behavior" \
  sh -c '[ "$1" -eq 0 ] && grep -q "pr merge 42" "$2"' sh "$vrc" "$GH_LOG"

# --- CI workflow, stable check names, wiring (AC2, AC4) ----------------------

echo "== workflow wiring and stable check names"

CI="$REPO_ROOT/.github/workflows/ci.yml"
check "ci.yml exists" test -f "$CI"
check "workflow name is stable (CI Gate)" grep -Fq 'name: CI Gate' "$CI"
check "job id is stable (quality-gate)" sh -c "grep -Eq '^  quality-gate:' '$CI'"
check "gate runs on ubuntu-latest" grep -Fq 'runs-on: ubuntu-latest' "$CI"
check "gate triggers on every pull request" grep -Fq 'pull_request' "$CI"
check "gate fetches full history for test-first evidence" \
  grep -Fq 'fetch-depth: 0' "$CI"
check "gate executes the configured commands via ci-gate.sh" \
  grep -Fq 'scripts/ci-gate.sh' "$CI"
check "stable check name documented as the required context" \
  grep -Fq 'CI Gate / quality-gate' "$CI"
check "setup.sh registers the stable check as required" \
  grep -Fq '"CI Gate / quality-gate"' "$REPO_ROOT/setup.sh"

PRW="$REPO_ROOT/.github/workflows/pr-review.yml"
gate_before_decider() {
  a=$(grep -n 'ci-gate.sh' "$1" | head -1 | cut -d: -f1)
  b=$(grep -n 'review-verdict.sh' "$1" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
check "pr-review runs the gate before the merge decider" \
  gate_before_decider "$PRW"
check "pr-review exports the evidence location" grep -Fq 'CI_GATE_EVIDENCE' "$PRW"
check "review-verdict consults the gate when merging" \
  sh -c "grep -Fq 'ci-gate.sh' '$REPO_ROOT/scripts/review-verdict.sh' \
    && grep -Fq 'CI_GATE_EVIDENCE' '$REPO_ROOT/scripts/review-verdict.sh'"
check "evidence dir stays untracked" \
  grep -Fq '.ci-evidence' "$REPO_ROOT/.gitignore"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
