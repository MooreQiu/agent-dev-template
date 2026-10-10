#!/usr/bin/env bash
# End-to-end validation of the autonomous lifecycle (issue #48).
#
# Unit tests for the individual entrypoints do not establish unattended
# completion: this suite wires the REAL orchestration chain (spec-start,
# spec-advance, agent-schedule, agent-task/agent-claim/agent-budget,
# pr-repair, review-verdict, ci-gate, spec-converge, spec-track) inside a
# disposable fixture repository with a file-backed origin and a mocked gh
# at the only remote boundary. The implementation "harness" is a small
# deterministic script standing in for the model agent, so every run is
# repeatable locally and in Actions.
#
# Scenarios (issue #48 acceptance criteria):
#   AC1  approved spec + task dependency chain + requirement-level and
#        integration assertions in the fixture
#   AC2  start-to-complete after one approval/start action; every later
#        stage transition is an authenticated workflow dispatch (asserted
#        at the gh boundary); no routine human triggers
#   AC3  injected rejected review + failing CI -> bounded repair rounds,
#        fresh independent review per pushed head, merge bound to the
#        repaired head (stale verdicts refused)
#   AC4  injected missing requirement -> convergence schedules remediation
#        before completion (no completion record until it merges)
#   AC5  duplicate events (start, dispatch, claim, on-drained run key),
#        interruption/recovery on the task branch, changed PR heads,
#        budget exhaustion/resume; no duplicate work, no unreviewed merge
#   AC6  redacted run ids, commit ids, verdicts, gate evidence,
#        requirement evidence and a final acceptance report, saved to
#        $E2E_REPORT_DIR (default: a run-local directory); deterministic
#        locally, and exercised as a real Actions smoke run by
#        .github/workflows/e2e-smoke.yml
#
# Run: bash tests/test-e2e-lifecycle.sh
# Debug: set E2E_KEEP=1 to preserve the fixture trees under $TMPDIR, and
# E2E_REPORT_DIR to choose the acceptance-report location (default: run-local).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-e2e-lifecycle.XXXXXX")"
cleanup() { [ -n "${E2E_KEEP:-}" ] || rm -rf "$TMP"; }
trap cleanup EXIT

# The report is a first-class deliverable (AC6): persistent when the caller
# (the e2e-smoke workflow) provides a directory, run-local otherwise.
REPORT_DIR="${E2E_REPORT_DIR:-$TMP/report}"
mkdir -p "$REPORT_DIR/artifacts" || exit 1

failures=0
ok()   { echo "ok - $1"; }
bad()  { echo "FAIL - $1${2:+ -- $2}"; failures=$((failures + 1)); }

check() { # check <description> <command...>
  d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

assert_rc() { # assert_rc <expected-rc> <description> <command...>
  want=$1; d=$2; shift 2
  log="$TMP/assert.log"
  set +e
  "$@" > "$log" 2>&1
  got=$?
  set -e
  if [ "$got" -eq "$want" ]; then
    ok "$d"
  else
    bad "$d" "expected exit $want, got $got: $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
  fi
}

assert_eq() { # assert_eq <got> <want> <description>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "got '$1', want '$2'"; fi
}

assert_contains() { # assert_contains <file> <fixed-string> <description>
  if grep -Fq -- "$2" "$1" 2>/dev/null; then
    ok "$3"
  else
    bad "$3" "missing '$2' in $1"
  fi
}

state_count() { # state_count <json-path-expression via argv node script>
  GH_STATE="$GH_STATE_DIR" node -e '
    const s = JSON.parse(require("fs").readFileSync(process.env.GH_STATE + "/state.json", "utf8"));
    console.log(eval(process.argv[1]));
  ' "$1" 2>/dev/null
}

# --- AC6 evidence recorder ----------------------------------------------------
# Every scenario records redacted ids and pointers; the report assembles them.
declare EVID_AC1="" EVID_AC2="" EVID_AC3="" EVID_AC4="" EVID_AC5="" EVID_AC6=""
evidence() { # evidence <AC> <line...>
  ac=$1; shift
  case "$ac" in
    AC1) EVID_AC1="${EVID_AC1}- $*
" ;;
    AC2) EVID_AC2="${EVID_AC2}- $*
" ;;
    AC3) EVID_AC3="${EVID_AC3}- $*
" ;;
    AC4) EVID_AC4="${EVID_AC4}- $*
" ;;
    AC5) EVID_AC5="${EVID_AC5}- $*
" ;;
    AC6) EVID_AC6="${EVID_AC6}- $*
" ;;
  esac
}
save_artifact() { # save_artifact <source> <artifact-name>
  [ -f "$1" ] || return 0
  sed "s#$TMP#<fixture>#g" "$1" > "$REPORT_DIR/artifacts/$2" 2>/dev/null
}

# Review run ids come from a file counter: callers run in command
# substitutions, so shell variables would not persist the increment.
next_run_id() {
  c="$(cat "$REVIEW_EV/.counter" 2>/dev/null || printf 0)"
  c=$((c + 1))
  mkdir -p "$REVIEW_EV"
  printf '%s' "$c" > "$REVIEW_EV/.counter"
  printf 'run-%04d' "$c"
}

# ============================================================================
# AC6 (wiring): the real Actions smoke run exists and follows the workflow
# conventions of this repository. Checked first so a missing wiring fails
# fast, before the multi-minute fixture scenarios.
# ============================================================================
SMOKE="$REPO_ROOT/.github/workflows/e2e-smoke.yml"
check "AC6: e2e smoke workflow exists" test -f "$SMOKE"
if [ -f "$SMOKE" ]; then
  assert_contains "$SMOKE" "tests/test-e2e-lifecycle.sh" \
    "AC6: smoke workflow runs this suite"
  assert_contains "$SMOKE" 'node-version: ${{ steps.node_pin.outputs.version }}' \
    "AC6: smoke workflow derives the node pin from project config"
  assert_contains "$SMOKE" "E2E_REPORT_DIR" \
    "AC6: smoke workflow persists the acceptance report location"
  assert_contains "$SMOKE" "actions/upload-artifact" \
    "AC6: smoke workflow uploads the acceptance report"
  check "AC6: smoke workflow is dispatchable" grep -q "workflow_dispatch" "$SMOKE"
fi

# ============================================================================
# Hermetic environment: the fixture must behave identically locally and in
# Actions, so ambient CI/repository variables never leak into it.
# ============================================================================
for v in GITHUB_ACTIONS GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_STEP_SUMMARY \
         GITHUB_OUTPUT GITHUB_WORKFLOW GITHUB_WORKFLOW_REF GITHUB_WORKSPACE \
         GITHUB_REPOSITORY GITHUB_TOKEN GH_TOKEN GH_REPO GITHUB_REF_NAME \
         CI_GATE_EVIDENCE AGENT_BUDGET_FILE AGENT_SPEC_REVISION \
         AGENT_REPAIR_PR AGENT_REPAIR_ISSUE AGENT_REPAIR_BRANCH \
         AGENT_REPAIR_REJECTED_HEAD AGENT_REPAIR_ROUND AGENT_REPAIR_MAX_ROUNDS \
         AGENT_REPAIR_FINDINGS AGENT_OWNER GITHUB_HEAD_REF GITHUB_BASE_REF; do
  unset "$v" 2>/dev/null || true
done
export GIT_AUTHOR_NAME=e2e-fixture GIT_AUTHOR_EMAIL=e2e-fixture@example.com
export GIT_COMMITTER_NAME=e2e-fixture GIT_COMMITTER_EMAIL=e2e-fixture@example.com
export GIT_AUTHOR_DATE="2026-10-10T00:00:00Z" GIT_COMMITTER_DATE="2026-10-10T00:00:00Z"

SCRIPTS="agent-claim.sh agent-budget.sh agent-schedule.sh agent-task.sh \
ci-gate.sh pr-repair.sh review-verdict.sh spec-advance.sh spec-converge.sh \
spec-converge-precheck.sh spec-start.sh spec-track.sh"
for s in $SCRIPTS; do
  [ -f "$REPO_ROOT/scripts/$s" ] || { bad "fixture script present: $s"; exit 1; }
done
ok "fixture scripts present in the repository"

# ============================================================================
# Mocked gh: file-backed state (issues, PRs, milestones, workflow runs) plus
# a mergebot clone so `gh pr merge` really advances the fixture origin, the
# way the GitHub merge does for the scheduler's merged-PR dependency gate.
# ============================================================================
MOCKGH="$TMP/mock-gh"
cat > "$MOCKGH" <<'MOCKGH_EOF'
#!/usr/bin/env bash
# Mock gh for the e2e fixture: serves state from $GH_STATE/state.json,
# records every call, and performs real git squash merges against the
# fixture bare origin via $GH_MERGE_DIR.
set -u
printf 'gh %s\n' "$*" >> "${GH_STATE}/gh.log"
STATE="${GH_STATE}/state.json"

args=("$@")
get_flag() { # get_flag <name> -> following value, empty when absent
  i=0
  for a in ${args[@]+"${args[@]}"}; do
    if [ "$a" = "$1" ]; then
      printf '%s' "${args[$((i + 1))]:-}"
      return 0
    fi
    i=$((i + 1))
  done
}
has_flag() {
  for a in ${args[@]+"${args[@]}"}; do
    [ "$a" = "$1" ] && return 0
  done
  return 1
}
nq() { # nq <node-script> [args...]
  s=$1
  shift
  STATE="$STATE" node -e "$s" "$@"
}

cmd="${1:-} ${2:-}"
case "$cmd" in
"repo view")
  echo "acme/e2e-fixture"
  ;;

"issue create")
  TITLE="$(get_flag --title)"; LABEL="$(get_flag --label)"
  MS="$(get_flag --milestone)"; BF="$(get_flag --body-file)"
  BODY="$(cat "$BF" 2>/dev/null || printf '')"
  nq '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
    const n = s.nextIssue++;
    s.issues.push({ number: n, title: process.argv[1], body: process.argv[2],
      state: "OPEN", labels: process.argv[3] ? [process.argv[3]] : [],
      milestone: process.argv[4] || "", assignees: [], comments: [] });
    fs.writeFileSync(process.env.STATE, JSON.stringify(s));
    console.log("https://github.com/acme/e2e-fixture/issues/" + n);
  ' "$TITLE" "$BODY" "$LABEL" "$MS"
  ;;

"issue list")
  JQ="$(get_flag --jq)"; MS="$(get_flag --milestone)"
  LABEL="$(get_flag --label)"
  case "$JQ" in
    *"!= null"*)
      # spec-track: number, title, blocked? for open milestone issues
      nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        for (const i of s.issues) {
          if (i.state === "OPEN" && i.milestone === process.argv[1]) {
            const b = i.labels.indexOf("blocked") >= 0;
            console.log([i.number, i.title, b].join("\t"));
          }
        }
      ' "$MS"
      ;;
    *"index(\"blocked\")"*)
      # spec-converge drain gate: open milestone issues without blocked
      nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        for (const i of s.issues) {
          if (i.state === "OPEN" && i.milestone === process.argv[1] &&
              i.labels.indexOf("blocked") < 0) {
            console.log([i.number, i.title].join("\t"));
          }
        }
      ' "$MS"
      ;;
    *"assignees"*)
      # agent-schedule queue: ready-for-agent open issues (most specific
      # shape first: it also contains "join", so match it before that)
      nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        for (const i of s.issues) {
          if (i.state === "OPEN" && i.labels.indexOf(process.argv[1]) >= 0) {
            console.log([i.number, i.labels.join(","),
              String(i.assignees.length), i.body].join("\t"));
          }
        }
      ' "$LABEL"
      ;;
    *"join"*)
      # spec-advance control scan: open milestone issues as label csv
      nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        for (const i of s.issues) {
          if (i.state === "OPEN" && i.milestone === process.argv[1]) {
            console.log([i.number, i.labels.join(",")].join("\t"));
          }
        }
      ' "$MS"
      ;;
    *".state"*)
      # spec-converge / spec-track existing: number, title, state
      nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        for (const i of s.issues) {
          console.log([i.number, i.title, i.state].join("\t"));
        }
      '
      ;;
    *)
      # spec-start existing: number, title
      nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        for (const i of s.issues) {
          console.log([i.number, i.title].join("\t"));
        }
      '
      ;;
  esac
  ;;

"issue view")
  N="$3"
  nq '
    const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
    const i = s.issues.find((x) => String(x.number) === process.argv[1]);
    if (!i) process.exit(1);
    if (String(process.argv[2]).indexOf("labels") >= 0) {
      console.log(JSON.stringify({ labels: i.labels.map((l) => ({ name: l })) }));
    } else if (String(process.argv[2]).indexOf("title") >= 0) {
      console.log(JSON.stringify({ title: i.title }));
    } else {
      console.log(JSON.stringify({ state: i.state }));
    }
  ' "$N" "$(get_flag --json)"
  ;;

"issue edit")
  N="$3"
  ADD="$(get_flag --add-label)"; RM="$(get_flag --remove-label)"
  nq '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
    const i = s.issues.find((x) => String(x.number) === process.argv[1]);
    if (!i) process.exit(1);
    if (process.argv[2] && i.labels.indexOf(process.argv[2]) < 0) {
      i.labels.push(process.argv[2]);
    }
    if (process.argv[3]) {
      i.labels = i.labels.filter((l) => l !== process.argv[3]);
    }
    fs.writeFileSync(process.env.STATE, JSON.stringify(s));
  ' "$N" "$ADD" "$RM"
  ;;

"issue comment")
  N="$3"; B="$(get_flag --body)"
  nq '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
    const i = s.issues.find((x) => String(x.number) === process.argv[1]);
    if (!i) process.exit(1);
    i.comments.push({ author: { login: "e2e-driver" }, body: process.argv[2] });
    fs.writeFileSync(process.env.STATE, JSON.stringify(s));
  ' "$N" "$B"
  ;;

"pr list")
  LABEL="$(get_flag --label)"; ST="$(get_flag --state)"
  if [ -n "$LABEL" ]; then
    # pr-repair scan: open PRs carrying the label
    nq '
      const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
      const out = s.prs.filter((p) => p.state === "OPEN" &&
        p.labels.indexOf(process.argv[1]) >= 0)
        .map((p) => ({ number: p.number, headRefName: p.headRefName }));
      console.log(JSON.stringify(out));
    ' "$LABEL"
  else
    nq '
      const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
      for (const p of s.prs) {
        if (p.state === process.argv[1].toUpperCase()) {
          console.log([p.number, p.body].join("\t"));
        }
      }
    ' "$ST"
  fi
  ;;

"pr view")
  KEY="$3"
  BR="$(nq '
    const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
    const p = s.prs.find((x) => x.headRefName === process.argv[1] ||
      String(x.number) === process.argv[1]);
    if (!p || p.state === "DELETED") process.exit(1);
    console.log(p.headRefName);
  ' "$KEY")"
  [ -n "$BR" ] || exit 1
  # GitHub always reports the live branch head, never a stale cache.
  LIVE="$(git -C "$GH_ORIGIN" rev-parse "refs/heads/$BR" 2>/dev/null || printf '')"
  nq '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
    const p = s.prs.find((x) => x.headRefName === process.argv[1] ||
      String(x.number) === process.argv[1]);
    if (!p || p.state === "DELETED") process.exit(1);
    console.log(JSON.stringify({ number: p.number, state: p.state,
      headRefOid: process.argv[2] || p.headRefOid,
      headRefName: p.headRefName, body: p.body,
      url: p.url, labels: p.labels,
      statusCheckRollup: p.statusCheckRollup, comments: p.comments }));
  ' "$KEY" "$LIVE"
  ;;

"pr create")
  HEAD="$(get_flag --head)"; BASE="$(get_flag --base)"
  TITLE="$(get_flag --title)"; BODY="$(get_flag --body)"
  SHA="$(git -C "$GH_ORIGIN" rev-parse "refs/heads/$HEAD" 2>/dev/null || printf '')"
  nq '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
    const n = s.nextPr++;
    s.prs.push({ number: n, state: "OPEN", headRefName: process.argv[1],
      headRefOid: process.argv[2], base: process.argv[3],
      title: process.argv[4], body: process.argv[5], labels: [],
      statusCheckRollup: [], comments: [], mergedSha: "",
      url: "https://github.com/acme/e2e-fixture/pull/" + n });
    fs.writeFileSync(process.env.STATE, JSON.stringify(s));
    console.log("https://github.com/acme/e2e-fixture/pull/" + n);
  ' "$HEAD" "$SHA" "$BASE" "$TITLE" "$BODY"
  ;;

"pr edit")
  N="$3"
  B="$(get_flag --body)"; ADD="$(get_flag --add-label)"; RM="$(get_flag --remove-label)"
  nq '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
    const p = s.prs.find((x) => String(x.number) === process.argv[1]);
    if (!p) process.exit(1);
    if (process.argv[2]) p.body = process.argv[2];
    if (process.argv[3] && p.labels.indexOf(process.argv[3]) < 0) {
      p.labels.push(process.argv[3]);
    }
    if (process.argv[4]) p.labels = p.labels.filter((l) => l !== process.argv[4]);
    fs.writeFileSync(process.env.STATE, JSON.stringify(s));
  ' "$N" "$B" "$ADD" "$RM"
  ;;

"pr comment")
  N="$3"; B="$(get_flag --body)"
  nq '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
    const p = s.prs.find((x) => String(x.number) === process.argv[1]);
    if (!p) process.exit(1);
    p.comments.push({ author: { login: "e2e-driver" }, body: process.argv[2] });
    fs.writeFileSync(process.env.STATE, JSON.stringify(s));
  ' "$N" "$B"
  ;;

"pr merge")
  N="$3"
  BRANCH="$(nq '
    const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
    const p = s.prs.find((x) => String(x.number) === process.argv[1]);
    if (!p) process.exit(1);
    console.log(p.headRefName);
  ' "$N")"
  PBODY="$(nq '
    const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
    const p = s.prs.find((x) => String(x.number) === process.argv[1]);
    console.log(p.body);
  ' "$N")"
  [ -n "$BRANCH" ] || exit 1
  d="$GH_MERGE_DIR"
  git -C "$d" fetch -q origin || exit 1
  git -C "$d" checkout -q main || exit 1
  git -C "$d" reset -q --hard origin/main || exit 1
  git -C "$d" merge --squash --quiet "origin/$BRANCH" || exit 1
  git -C "$d" commit -q -m "Merge PR #$N (squash $BRANCH)" || exit 1
  git -C "$d" push -q origin main || exit 1
  git -C "$d" push -q origin ":refs/heads/$BRANCH" 2>/dev/null || true
  MERGED="$(git -C "$d" rev-parse HEAD)"
  nq '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
    const p = s.prs.find((x) => String(x.number) === process.argv[1]);
    p.state = "MERGED";
    p.mergedSha = process.argv[2];
    for (const m of process.argv[3].matchAll(/(?:Closes|Fixes|Resolves) #(\d+)/g)) {
      const i = s.issues.find((x) => String(x.number) === m[1]);
      if (i) i.state = "CLOSED";
    }
    fs.writeFileSync(process.env.STATE, JSON.stringify(s));
  ' "$N" "$MERGED" "$PBODY"
  ;;

"run list")
  WF="$(get_flag --workflow)"; BR="$(get_flag --branch)"
  case "$WF" in
    pr-review.yml)
      nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        const runs = s.runs.filter((r) => r.workflow === "pr-review.yml" &&
          (!process.argv[1] || r.branch === process.argv[1]))
          .map((r) => ({ headSha: r.headSha, status: r.status }));
        console.log(JSON.stringify(runs));
      ' "$BR"
      ;;
    spec-converge.yml)
      nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        for (const r of s.runs) {
          if (r.workflow === "spec-converge.yml") {
            console.log([r.displayTitle, r.status].join("\t"));
          }
        }
      '
      ;;
    *)
      echo "[]"
      ;;
  esac
  ;;

"workflow run")
  printf "workflow-run %s\n" "${args[*]}" >> "${GH_STATE}/dispatch.log"
  rc="$(cat "${GH_STATE}/dispatch-rc" 2>/dev/null || printf 0)"
  case "$rc" in ""|*[!0-9]*) rc=0 ;; esac
  exit "$rc"
  ;;

"api"*)
  # gh api [-X METHOD] <path> [-f key=value] [--jq <program>]
  if [ "${2:-}" = "-X" ]; then
    # gh api -X PATCH repos/.../milestones/N -f state=closed
    nq '
      const fs = require("fs");
      const s = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
      const n = String(process.argv[1]).split("/").pop();
      const m = s.milestones.find((x) => String(x.number) === n);
      if (m) m.state = process.argv[2] || m.state;
      fs.writeFileSync(process.env.STATE, JSON.stringify(s));
    ' "$4" "$(get_flag -f | sed -n 's/^state=//p')"
    exit 0
  fi
  P="$2"
  case "$P" in
    */pulls/*)
      N="${P##*/}"
      BR="$(nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        const p = s.prs.find((x) => String(x.number) === process.argv[1]);
        if (!p) process.exit(1);
        console.log(p.headRefName);
      ' "$N")"
      LIVE="$(git -C "$GH_ORIGIN" rev-parse "refs/heads/$BR" 2>/dev/null || printf '')"
      nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        const p = s.prs.find((x) => String(x.number) === process.argv[1]);
        if (!p) process.exit(1);
        console.log(JSON.stringify({ number: p.number, state: p.state,
          head: { sha: process.argv[2] || p.headRefOid,
                  ref: p.headRefName } }));
      ' "$N" "$LIVE"
      ;;
    */milestones)
      if has_flag "-f"; then
        TITLE="$(get_flag -f | sed -n 's/^title=//p')"
        nq '
          const fs = require("fs");
          const s = JSON.parse(fs.readFileSync(process.env.STATE, "utf8"));
          if (!s.milestones.some((m) => m.title === process.argv[1])) {
            const n = s.nextMilestone++;
            s.milestones.push({ number: n, title: process.argv[1], state: "open" });
          }
          fs.writeFileSync(process.env.STATE, JSON.stringify(s));
        ' "$TITLE"
        exit 0
      fi
      JQ="$(get_flag --jq)"
      FIELD="number"
      case "$JQ" in
        *".state"*) FIELD="state" ;;
      esac
      TITLE="$(printf '%s' "$JQ" | sed -n 's/.*select(.title == "\([^"]*\)").*/\1/p')"
      nq '
        const s = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
        const m = s.milestones.find((x) => x.title === process.argv[1]);
        if (m && process.argv[2]) console.log(m[process.argv[2]]);
      ' "$TITLE" "$FIELD"
      ;;
    *)
      echo "mock gh: unhandled api path: $P" >&2
      exit 1
      ;;
  esac
  ;;

*)
  echo "mock gh: unhandled arguments: ${args[*]}" >&2
  exit 1
  ;;
esac
exit 0
MOCKGH_EOF
chmod +x "$MOCKGH"

# Deterministic stand-ins for the agent harnesses (written once, seeded into
# every fixture repository).
HARNESS_IMPL="$TMP/harness-impl.sh"
cat > "$HARNESS_IMPL" <<'IMPL_EOF'
#!/bin/sh
# Fixture harness: deterministic stand-in for the implementation agent.
# Env: HARNESS_TASK (T001|T002|T003|REM), HARNESS_MODE (""|crash|edge-test-only|fix)
set -u
MODE="${HARNESS_MODE:-}"
commit() {
  git add -A
  git diff --cached --quiet || git commit -q -m "$1"
}

write_req_test() { # write_req_test <req>
  cat > "tests/test-$1.sh" <<EOT
#!/bin/sh
set -u
out="\$(bash "src/$1.sh" 2>/dev/null || true)"
[ "\$out" = "$1-ok" ] || { echo "FAIL: $1 not satisfied"; exit 1; }
echo "ok - $1"
EOT
  chmod +x "tests/test-$1.sh"
}

case "${HARNESS_TASK:-}" in
  T001)
    [ -f tests/test-req1.sh ] || { write_req_test req1; commit "Add failing requirement test for REQ1"; }
    [ -f src/req1.sh ] || { mkdir -p src; printf '#!/bin/sh\nprintf "req1-ok\\n"\n' > src/req1.sh; commit "Implement REQ1"; }
    ;;
  T002)
    [ -f tests/test-req2.sh ] || {
      cat > tests/test-req2.sh <<'EOT'
#!/bin/sh
set -u
out="$(bash src/req2.sh 2>/dev/null || true)"
[ "$out" = "req2-ok" ] || { echo "FAIL: REQ2 default behavior missing"; exit 1; }
echo "ok - req2 default"
EOT
      chmod +x tests/test-req2.sh
      commit "Add failing requirement test for REQ2"
    }
    if [ "$MODE" = "edge-test-only" ] || [ "$MODE" = "fix" ]; then
      [ -f tests/test-req2-edge.sh ] || {
        cat > tests/test-req2-edge.sh <<'EOT'
#!/bin/sh
set -u
out="$(bash src/req2.sh --flag 2>/dev/null || true)"
[ "$out" = "req2-edge-ok" ] || { echo "FAIL: REQ2 edge behavior missing"; exit 1; }
echo "ok - req2 edge"
EOT
        chmod +x tests/test-req2-edge.sh
        commit "Add failing edge-case test for REQ2 (review finding)"
      }
    fi
    if [ ! -f src/req2.sh ]; then
      mkdir -p src
      printf '#!/bin/sh\nprintf "req2-ok\\n"\n' > src/req2.sh
      commit "Implement REQ2 default behavior"
    fi
    if [ "$MODE" = "fix" ]; then
      printf '#!/bin/sh\ncase "$1" in --flag) printf "req2-edge-ok\\n" ;; *) printf "req2-ok\\n" ;; esac\n' > src/req2.sh
      commit "Implement REQ2 edge handling (repair)"
    fi
    ;;
  T003)
    [ -f tests/test-integration.sh ] || {
      cat > tests/test-integration.sh <<'EOT'
#!/bin/sh
set -u
[ -f src/pipeline.sh ] || { echo "FAIL: integration pipeline missing"; exit 1; }
out="$(bash src/pipeline.sh 2>/dev/null || true)"
case "$out" in
  *req1-ok*req2-ok*) echo "ok - integration" ;;
  *) echo "FAIL: pipeline output incomplete: $out"; exit 1 ;;
esac
EOT
      chmod +x tests/test-integration.sh
      commit "Add failing integration assertion for SC-1"
    }
    if [ "$MODE" = "crash" ]; then
      # Interrupted run: publish the red commit, then die before implementing.
      git push -q origin "HEAD:refs/heads/agent/issue-${HARNESS_ISSUE:?}"
      echo "harness: interrupted after publishing partial work" >&2
      exit 1
    fi
    [ -f src/pipeline.sh ] || {
      mkdir -p src
      printf '#!/bin/sh\nprintf "req1-ok req2-ok\\n"\n' > src/pipeline.sh
      commit "Implement SC-1 integration pipeline"
    }
    ;;
  REM)
    [ -f tests/test-req3.sh ] || { write_req_test req3; commit "Add failing requirement test for REQ3 (remediation)"; }
    if [ ! -f src/req3.sh ]; then
      printf '#!/bin/sh\nprintf "req3-ok\\n"\n' > src/req3.sh
      commit "Implement REQ3 audit report"
    fi
    if [ -f src/pipeline.sh ] && ! grep -q req3-ok src/pipeline.sh; then
      printf '#!/bin/sh\nprintf "req1-ok req2-ok req3-ok\\n"\n' > src/pipeline.sh
      commit "Extend SC-1 pipeline with REQ3 evidence"
    fi
    ;;
  *)
    echo "harness: unknown HARNESS_TASK '${HARNESS_TASK:-}'" >&2
    exit 1
    ;;
esac
git push -q origin "HEAD:refs/heads/agent/issue-${HARNESS_ISSUE:?}"
IMPL_EOF
chmod +x "$HARNESS_IMPL"

HARNESS_REPAIR="$TMP/harness-repair.sh"
cat > "$HARNESS_REPAIR" <<'REPAIR_EOF'
#!/bin/sh
# Fixture harness for rejected-PR repair scenarios (no spec in play).
# Env: REPAIR_ISSUE (90|91|92), REPAIR_MODE (""|no-op|break|fix|slow-fix)
set -u
MODE="${REPAIR_MODE:-no-op}"
N="${REPAIR_ISSUE:?}"
F="src/feature$N.sh"
commit() {
  git add -A
  git diff --cached --quiet || git commit -q -m "$1"
}
write_edge_test() {
  cat > "tests/test-feature$N-edge.sh" <<EOT
#!/bin/sh
set -u
out="\$(bash $F --flag 2>/dev/null || true)"
[ "\$out" = "feature$N-edge-ok" ] || { echo "FAIL: edge missing"; exit 1; }
echo ok
EOT
}
case "$MODE" in
  no-op) : ;;
  break)
    printf "BROKEN\n" > "$F"
    commit "Apply defective repair (round progress)"
    ;;
  fix|slow-fix)
    [ "$MODE" = "slow-fix" ] && sleep 6
    [ -f "tests/test-feature$N-edge.sh" ] || {
      write_edge_test
      commit "Add failing edge test from review findings"
    }
    printf '#!/bin/sh\ncase "${1:-}" in --flag) printf "feature%s-edge-ok\\n" ;; *) printf "feature%s-ok\\n" ;; esac\n' "$N" "$N" > "$F"
    commit "Repair reviewed defect with edge handling"
    ;;
  *) echo "harness: unknown REPAIR_MODE '$MODE'" >&2; exit 1 ;;
esac
git push -q origin "HEAD:refs/heads/agent/issue-$N"
REPAIR_EOF
chmod +x "$HARNESS_REPAIR"

# ============================================================================
# Fixture builders
# ============================================================================
new_mock() { # new_mock <state-dir>
  GH_STATE_DIR="$1"
  mkdir -p "$GH_STATE_DIR/bin"
  cp "$MOCKGH" "$GH_STATE_DIR/bin/gh"
  chmod +x "$GH_STATE_DIR/bin/gh"
  printf '{"issues":[],"prs":[],"milestones":[],"runs":[],"nextIssue":1,"nextPr":101,"nextMilestone":1}\n' \
    > "$GH_STATE_DIR/state.json"
  : > "$GH_STATE_DIR/dispatch.log"
  printf '0\n' > "$GH_STATE_DIR/dispatch-rc"
  GH_STATE="$GH_STATE_DIR"
  export GH_STATE
}

copy_scripts() { # copy_scripts <dest-dir>
  mkdir -p "$1"
  for s in $SCRIPTS; do
    cp "$REPO_ROOT/scripts/$s" "$1/$s"
  done
}

FIXTURE_PROJECT='{
  "commands": {
    "install": "",
    "build": "",
    "test": "bash tests/run-all.sh",
    "lint": "",
    "typecheck": ""
  },
  "runtime": {
    "version": "24"
  }
}'

FIXTURE_RUN_ALL='#!/bin/sh
set -u
cd "$(dirname "$0")/.."
status=0
for t in tests/test*.sh; do
  [ -e "$t" ] || continue
  bash "$t" || status=1
done
exit "$status"
'

# make_fixture <dir> <budgets-json> <variant: lifecycle|repair>
make_fixture() {
  fx="$1"; budgets="$2"; variant="$3"
  mkdir -p "$fx/origin" "$fx/seed/scripts" "$fx/seed/tests" "$fx/seed/.agent"
  copy_scripts "$fx/seed/scripts"
  cp "$HARNESS_IMPL" "$fx/seed/scripts/harness-impl.sh"
  cp "$HARNESS_REPAIR" "$fx/seed/scripts/harness-repair.sh"
  printf '%s\n' "$FIXTURE_PROJECT" > "$fx/seed/.agent/project.json"
  printf '%s\n' "$budgets" > "$fx/seed/.agent/budgets.json"
  printf '%s\n' "$FIXTURE_RUN_ALL" > "$fx/seed/tests/run-all.sh"
  chmod +x "$fx/seed/tests/run-all.sh"

  if [ "$variant" = lifecycle ]; then
    mkdir -p "$fx/seed/specs/050-e2e"
    cat > "$fx/seed/specs/050-e2e/spec.md" <<'EOSPEC'
# Spec: 050-e2e

## Requirements
- REQ1 The pipeline emits the REQ1 greeting.
- REQ2 The pipeline emits the REQ2 greeting and honors --flag on the edge.
- REQ3 The pipeline emits the REQ3 audit report.
- SC-1 The integrated pipeline composes REQ1 and REQ2 into one run.
EOSPEC
    cat > "$fx/seed/specs/050-e2e/plan.md" <<'EOPLAN'
# Plan: 050-e2e
Approach derived from the approved spec: one module per requirement and a
pipeline composition covered by the integration assertion.
EOPLAN
    cat > "$fx/seed/specs/050-e2e/tasks.md" <<'EOTASKS'
# Tasks: 050-e2e

## Phase 1
- [ ] T001 Implement the REQ1 greeting module
- [ ] T002 Implement the REQ2 greeting module (depends on T001)
- [ ] T003 Wire the SC-1 integration pipeline (depends on T002)
EOTASKS
  fi
  if [ "$variant" = repair ]; then
    mkdir -p "$fx/seed/src"
    printf '#!/bin/sh\nprintf "base-ok\\n"\n' > "$fx/seed/src/base.sh"
    cat > "$fx/seed/tests/test-base.sh" <<'EOT'
#!/bin/sh
set -u
out="$(bash src/base.sh 2>/dev/null || true)"
[ "$out" = "base-ok" ] || exit 1
echo ok
EOT
  fi
  cat > "$fx/seed/.gitignore" <<'EOIGN'
.agent-work/
.agent/runs/
.agent/repair/
.ci-evidence/
EOIGN

  git init -q --bare "$fx/origin/origin.git"
  git -C "$fx/origin/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$fx/seed" init -q
  git -C "$fx/seed" add -A
  git -C "$fx/seed" commit -qm "seed: pipeline scripts, fixture feature, budgets"
  git -C "$fx/seed" remote add origin "$fx/origin/origin.git"
  git -C "$fx/seed" push -q origin HEAD:refs/heads/main

  git clone -q "$fx/origin/origin.git" "$fx/runner"
  git -C "$fx/runner" config user.name runner
  git -C "$fx/runner" config user.email runner@example.com
  if [ "$variant" = repair ]; then
    # A second worker checkout: duplicate dispatch events arrive at their
    # own clone, exactly like two workflow runs on the shared origin.
    git clone -q "$fx/origin/origin.git" "$fx/runner2"
    git -C "$fx/runner2" config user.name runner2
    git -C "$fx/runner2" config user.email runner2@example.com
  fi
  git clone -q "$fx/origin/origin.git" "$fx/verify"
  git -C "$fx/verify" config user.name verifier
  git -C "$fx/verify" config user.email verifier@example.com
  git clone -q "$fx/origin/origin.git" "$fx/mergebot"
  git -C "$fx/mergebot" config user.name mergebot
  git -C "$fx/mergebot" config user.email mergebot@example.com
}

# make_branch_pr <fixture> <issue> <pr>
# Seed an agent branch with a green-but-defective feature and an open,
# rejected PR (REQUEST_CHANGES comment + failing check + completed review).
make_branch_pr() {
  fx="$1"; issue="$2"; pr="$3"
  work="$fx/rejected-$issue"
  git clone -q "$fx/origin/origin.git" "$work"
  git -C "$work" config user.name fixture
  git -C "$work" config user.email fixture@example.com
  git -C "$work" checkout -q -b "agent/issue-$issue" origin/main
  mkdir -p "$work/src" "$work/tests"
  cat > "$work/tests/test-feature$issue.sh" <<EOT
#!/bin/sh
set -u
out="\$(bash src/feature$issue.sh 2>/dev/null || true)"
[ "\$out" = "feature$issue-ok" ] || { echo "FAIL: feature broken"; exit 1; }
echo ok
EOT
  git -C "$work" add -A
  git -C "$work" commit -qm "Add failing test for feature $issue"
  printf '#!/bin/sh\nprintf "feature%s-ok\\n"\n' "$issue" > "$work/src/feature$issue.sh"
  git -C "$work" add -A
  git -C "$work" commit -qm "Implement feature $issue (defective: no edge handling)"
  git -C "$work" push -q origin "HEAD:refs/heads/agent/issue-$issue"
  head="$(git -C "$work" rev-parse HEAD)"
  GH_STATE="$GH_STATE_DIR" node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.GH_STATE + "/state.json", "utf8"));
    const issue = Number(process.argv[1]);
    s.issues.push({ number: issue, title: "[fixture] feature " + issue,
      body: "fixture task", state: "OPEN", labels: ["agent-failed"],
      milestone: "", assignees: [], comments: [] });
    const pr = Number(process.argv[2]);
    const head = process.argv[3];
    s.prs.push({ number: pr, state: "OPEN", headRefName: "agent/issue-" + issue,
      headRefOid: head, base: "main", title: "agent/issue-" + issue,
      body: "Automated task run for #" + issue + ". Closes #" + issue,
      labels: ["agent-failed"],
      statusCheckRollup: [{ name: "CI Gate / quality-gate", conclusion: "FAILURE" }],
      comments: [{ author: { login: "agent-review-bot" },
        body: "VERDICT: REQUEST_CHANGES - blocking issues:\n- untested edge behavior" }],
      mergedSha: "", url: "https://github.com/acme/e2e-fixture/pull/" + pr });
    s.runs.push({ workflow: "pr-review.yml", branch: "agent/issue-" + issue,
      headSha: head, status: "completed", id: "seeded", displayTitle: "" });
    fs.writeFileSync(process.env.GH_STATE + "/state.json", JSON.stringify(s));
  ' "$issue" "$pr" "$head"
  printf '%s\n' "$head" > "$fx/rejected-$issue-head"
}

registry_json() { # registry_json <runner-clone> <key> -> repair registry JSON
  git -C "$1" fetch -q origin "refs/agent-repairs/$2" 2>/dev/null || true
  git -C "$1" rev-parse --verify -q FETCH_HEAD >/dev/null 2>&1 || return 0
  git -C "$1" cat-file commit FETCH_HEAD 2>/dev/null | sed '1,/^$/d'
}

remote_ref_exists() { # remote_ref_exists <clone> <ref>
  git -C "$1" ls-remote origin "$2" 2>/dev/null | grep -q .
}

remote_ref_absent() { # usable inside check: the ref must not exist
  ! remote_ref_exists "$1" "$2"
}

in_dir() { # in_dir <clone> <command...>: run a fixture entrypoint with the
  # fixture clone as the working tree -- the unified pipeline derives the
  # repository root from the cwd, so ambient cwds must never leak in
  _in_dir_target=$1
  shift
  ( cd "$_in_dir_target" && "$@" )
}
# Fixture stage entrypoints cd to their own repository root, but every
# orchestration call below still runs inside the fixture clones so git
# remotes, registry refs, and repo_root all resolve to the fixture.

# ============================================================================
# PHASE A: one approval -> autonomous start-to-complete (AC1/AC2/AC3/AC4/AC5)
# ============================================================================
FX="$TMP/lifecycle"
new_mock "$FX/gh"
GH_ORIGIN="$FX/origin/origin.git"
GH_MERGE_DIR="$FX/mergebot"
export GH_ORIGIN GH_MERGE_DIR
ORIG_PATH="$PATH"
PATH="$FX/gh/bin:$ORIG_PATH"
export PATH

make_fixture "$FX" \
  '{"max_attempts_per_issue": 3, "max_repair_rounds": 3, "max_convergence_rounds": 3}' \
  lifecycle
RUNNER="$FX/runner"
VERIFY="$FX/verify"
SPEC="specs/050-e2e/spec.md"

# --- the single human action: approve the seed revision -----------------------
R1="$(git -C "$FX/seed" rev-parse HEAD)"
cat > "$FX/seed/specs/050-e2e/approval.json" <<EOAPP
{
  "spec": "$SPEC",
  "revision": "$R1",
  "approved_by": "human-reviewer",
  "approved_at": "2026-10-10T00:00:00Z"
}
EOAPP
git -C "$FX/seed" add -A
git -C "$FX/seed" commit -qm "Record human approval for 050-e2e"
git -C "$FX/seed" push -q origin HEAD:refs/heads/main
git -C "$RUNNER" fetch -q origin
git -C "$RUNNER" checkout -q -B main origin/main
git -C "$VERIFY" fetch -q origin
git -C "$VERIFY" checkout -q -B main origin/main
evidence "AC1" "fixture feature 050-e2e approved at revision $R1 (approved_by=human-reviewer)"
evidence "AC1" "task dependency chain: T001 <- T002 <- T003 in specs/050-e2e/tasks.md"

# --- spec-start: planning artifacts -> issues with dependency metadata --------
START_JSON="$(in_dir "$RUNNER" bash scripts/spec-start.sh "$SPEC" "$R1" --json 2>"$TMP/start.err")" \
  && ok "AC2: spec-start generated the task queue" \
  || bad "AC2: spec-start generated the task queue" "$(cat "$TMP/start.err")"
assert_eq "$(printf '%s' "$START_JSON" | sed -n 's/.*"created":\[\([^]]*\)\].*/\1/p')" "1,2,3" \
  "AC1: spec-start created one issue per task with a milestone queue"
check "AC2: spec-start queued tasks as ready-for-agent" \
  grep -q '"ready-for-agent"' "$GH_STATE_DIR/state.json"
I1="1"; I2="2"; I3="3"
evidence "AC2" "approval/start action: spec-start created issues $I1,$I2,$I3 (ready-for-agent)"

# Duplicate start event: idempotent, no duplicate work (AC5).
DUP_JSON="$(in_dir "$RUNNER" bash scripts/spec-start.sh "$SPEC" "$R1" --json 2>/dev/null)" \
  && ok "AC5: duplicate spec-start event absorbed" \
  || bad "AC5: duplicate spec-start event absorbed"
assert_eq "$(printf '%s' "$DUP_JSON" | sed -n 's/.*"created":\[\([^]]*\)\].*/\1/p')" "" \
  "AC5: duplicate spec-start created no issues"
assert_eq "$(state_count "s.issues.length")" "3" \
  "AC5: duplicate start produced no duplicate issues"

# --- after-start: authenticated scheduler dispatch (AC2/AC3) -------------------
in_dir "$VERIFY" bash scripts/spec-advance.sh after-start "$SPEC" "$R1" --json >/dev/null 2>&1 \
  && ok "AC2: after-start dispatched the scheduler autonomously" \
  || bad "AC2: after-start dispatched the scheduler autonomously"
assert_contains "$GH_STATE_DIR/dispatch.log" "workflow run agent-scheduler.yml" \
  "AC2: after-start dispatched agent-scheduler.yml"

# --- review emulation helper ---------------------------------------------------
# Emulates pr-review.yml on the head of a task worktree: deterministic CI gate
# evidence + an independent review report distilled into a verdict artifact
# bound to the exact head SHA and workflow run id.
REVIEW_EV="$TMP/reviews"
mkdir -p "$REVIEW_EV"
freshen_review() { # freshen_review <branch> <head>: emulate the synchronize
  # review of a newly pushed head (the push fired a fresh completed review)
  GH_STATE="$GH_STATE_DIR" node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.GH_STATE + "/state.json", "utf8"));
    const runs = s.runs.filter((r) => r.workflow === "pr-review.yml" &&
      r.branch === process.argv[1]);
    const r = runs[runs.length - 1];
    if (r) r.headSha = process.argv[2];
    fs.writeFileSync(process.env.GH_STATE + "/state.json", JSON.stringify(s));
  ' "$1" "$2"
}
review_run() { # review_run <worktree> <pr> <verdict> <run-id>
  wt="$1"; pr="$2"; verdict="$3"; rid="$4"
  ev="$REVIEW_EV/$rid"
  mkdir -p "$ev"
  head="$(git -C "$wt" rev-parse HEAD)"
  branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
  if [ "$verdict" = APPROVE ]; then
    cat > "$ev/report.md" <<EOR
$rid
Independent review of $branch @${head}.

Findings: requirement assertions and the integration assertion are present
and green; the diff carries its failing-test commit; scope matches the task.

VERDICT: APPROVE
EOR
  else
    cat > "$ev/report.md" <<EOR
$rid
Independent review of $branch @${head}.

Findings: the reviewed behavior mishandles the edge case and no test covers
it; the CI gate evidence for this head is also failing.

VERDICT: REQUEST_CHANGES
EOR
  fi
  bash "$wt/scripts/ci-gate.sh" run --base origin/main --target-dir "$wt" \
    --evidence-dir "$ev" > "$ev/gate-run.log" 2>&1 || true
  GITHUB_ACTIONS=true GITHUB_RUN_ID="$rid" GITHUB_RUN_ATTEMPT=1 \
  GITHUB_REPOSITORY=acme/e2e-fixture \
    bash "$wt/scripts/review-verdict.sh" write "$pr" \
      --reviewer-output "$ev/report.md" --head-sha "$head" \
      --evidence-dir "$ev" --artifact "$ev/review-verdict.json" \
      > "$ev/write.log" 2>&1 || {
        bad "review $rid: verdict write for PR #$pr failed" "$(cat "$ev/write.log")" >&2
        printf '%s\n' "WRITE-FAILED $rid"
        return 1
      }
  GH_STATE="$GH_STATE_DIR" node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.GH_STATE + "/state.json", "utf8"));
    s.runs.push({ workflow: "pr-review.yml", branch: process.argv[1],
      headSha: process.argv[2], status: "completed", id: process.argv[3],
      displayTitle: "" });
    fs.writeFileSync(process.env.GH_STATE + "/state.json", JSON.stringify(s));
  ' "$branch" "$head" "$rid"
  save_artifact "$ev/review-verdict.json" "verdict-$rid.json"
  save_artifact "$ev/gate.json" "gate-$rid.json"
  save_artifact "$ev/test-first.json" "test-first-$rid.json"
  printf '%s\n' "$rid $head $ev"
}

merge_verdict() { # merge_verdict <pr-checkout> <pr> <run-id> <evidence-dir> -> rc
  # The merge decider runs inside the review workflow's checkout of the
  # reviewed head: ci-gate check resolves the red commit against HEAD there.
  wt="$1"; pr="$2"; rid="$3"; ev="$4"
  in_dir "$wt" env GITHUB_ACTIONS=true GITHUB_RUN_ID="$rid" GITHUB_RUN_ATTEMPT=1 \
    GITHUB_REPOSITORY=acme/e2e-fixture \
    bash scripts/review-verdict.sh merge "$pr" \
      --evidence-dir "$ev" > "$TMP/merge-$pr-$rid.log" 2>&1
}

run_task() { # run_task <issue> <task-id> <mode>  (the unified pipeline)
  issue="$1"; task="$2"; mode="$3"
  in_dir "$RUNNER" env HARNESS_TASK="$task" HARNESS_MODE="$mode" HARNESS_ISSUE="$issue" \
    bash scripts/agent-task.sh run "$issue" --target origin/main \
    --owner "e2e-worker-$$" -- bash scripts/harness-impl.sh
}

# --- T001: clean task round ------------------------------------------------------
sel="$(in_dir "$RUNNER" bash scripts/agent-schedule.sh next 2>/dev/null)"
assert_eq "${sel:-}" "$I1" "AC1: scheduler selects T001 first (dependency chain)"
assert_rc 0 "AC2: unified pipeline completes T001" \
  run_task "$I1" T001 ""
WT1="$RUNNER/.agent-work/issue-$I1"
rid1="$(next_run_id)"
res="$(review_run "$WT1" 101 APPROVE "$rid1")"
rest1="${res#* }"; head1="${rest1%% *}"; ev1="${rest1#* }"
assert_rc 0 "AC2: merge of T001 bound to reviewed head ${head1:0:12}" \
  merge_verdict "$WT1" 101 "$rid1" "$ev1"
evidence "AC2" "T001: review run $rid1 on ${head1:0:12}; merged (squash) bound to the same head"
check "AC2: T001 issue closed by the merge" \
  grep -q '"number":1,[^}]*"state":"CLOSED"' "$GH_STATE_DIR/state.json"
check "AC5: merges are squash merges from verified APPROVE verdicts" \
  test "$(git -C "$FX/origin/origin.git" rev-list --merges main 2>/dev/null | wc -l | tr -d ' ')" = "0"

# Sweep recovery hygiene: succeeded claim cleaned once the issue closed.
in_dir "$RUNNER" bash scripts/agent-claim.sh reconcile >/dev/null 2>&1 || true
check "AC5: reconcile cleans the succeeded claim of closed issue $I1" \
  remote_ref_absent "$RUNNER" "refs/agent-claims/$I1"

# --- T002: rejected review + failing CI -> bounded repair -> fresh review ----
sel="$(in_dir "$RUNNER" bash scripts/agent-schedule.sh next 2>/dev/null)"
assert_eq "${sel:-}" "$I2" "AC1: T002 eligible only after T001 merged"
assert_rc 0 "AC2: unified pipeline completes T002 (initial implementation)" \
  run_task "$I2" T002 ""
WT2="$RUNNER/.agent-work/issue-$I2"
head_impl="$(git -C "$WT2" rev-parse HEAD)"

# Fresh independent review rejects the head; merge must stay forbidden.
rid_r1="$(next_run_id)"
res="$(review_run "$WT2" 102 REQUEST_CHANGES "$rid_r1")"
ev_r1="${res#* }"; ev_r1="${ev_r1#* }"
set +e
merge_verdict "$WT2" 102 "$rid_r1" "$ev_r1"
merge_rc=$?
set -e
assert_eq "$merge_rc" "0" \
  "AC3: REQUEST_CHANGES verdict handled (requeue, not a merge authorization)"
pr102="$(GH_STATE="$GH_STATE_DIR" node -e '
  const s = JSON.parse(require("fs").readFileSync(process.env.GH_STATE + "/state.json", "utf8"));
  const p = s.prs.find((x) => x.number === 102);
  console.log(p.state + " " + p.labels.join(","));')"
assert_eq "$pr102" "OPEN agent-failed" \
  "AC3: rejected PR 102 stays open, labeled agent-failed"
evidence "AC3" "PR 102 review run $rid_r1: VERDICT: REQUEST_CHANGES on ${head_impl:0:12}; merge refused"

# Rejection event -> repair loop (bounded by max_repair_rounds).
set +e
HARNESS_TASK=T002 HARNESS_MODE=edge-test-only HARNESS_ISSUE=$I2 \
  in_dir "$RUNNER" bash scripts/pr-repair.sh dispatch 102 --rejected-head "$head_impl" \
  -- bash scripts/harness-impl.sh
repair1_rc=$?
set -e
assert_eq "$repair1_rc" "4" "AC3: repair round 1 (failing CI) fails verification and stays queued"
head_r1="$(git -C "$FX/origin/origin.git" rev-parse "refs/heads/agent/issue-$I2")"
reg1="$(registry_json "$RUNNER" "$I2")"
check "AC3: repair round 1 recorded durably" \
  grep -Fq '"rounds":1' <<< "${reg1:-}"
evidence "AC3" "repair round 1 on ${head_r1:0:12}: injected failing CI (edge test red at HEAD); round failed rc 4"

# The pushed (still red) head gets its own fresh independent review.
rid_r2="$(next_run_id)"
res="$(review_run "$WT2" 102 REQUEST_CHANGES "$rid_r2")"
rest_r2="${res#* }"; head_r1rev="${rest_r2%% *}"; ev_r2="${rest_r2#* }"

# Round 2: repair completes the fix; verification turns green.
set +e
HARNESS_TASK=T002 HARNESS_MODE=fix HARNESS_ISSUE=$I2 \
  in_dir "$RUNNER" bash scripts/pr-repair.sh dispatch 102 --rejected-head "$head_r1rev" \
  -- bash scripts/harness-impl.sh
repair2_rc=$?
set -e
assert_eq "$repair2_rc" "0" "AC3: repair round 2 verified green and returned PR 102 to review"
head_r2="$(git -C "$FX/origin/origin.git" rev-parse "refs/heads/agent/issue-$I2")"
reg2="$(registry_json "$RUNNER" "$I2")"
check "AC3: repair rounds bounded and tracked" \
  grep -Fq '"rounds":2' <<< "${reg2:-}"
check "AC3: repair moved the head (progress)" test "$head_r2" != "$head_r1"

# Fresh independent review of the repaired head approves it.
rid_g1="$(next_run_id)"
res="$(review_run "$WT2" 102 APPROVE "$rid_g1")"
rest_g1="${res#* }"; head_g1="${rest_g1%% *}"; ev_g1="${rest_g1#* }"
check "AC3: fresh review is bound to the repaired head" test "$head_g1" = "$head_r2"

# Stale approvals must never merge: rejected gate evidence, a reviewed head
# that is no longer live, or a verdict from another workflow run.
set +e
GITHUB_ACTIONS=true GITHUB_RUN_ID="$rid_r1" GITHUB_RUN_ATTEMPT=1 \
GITHUB_REPOSITORY=acme/e2e-fixture \
  in_dir "$RUNNER" bash scripts/review-verdict.sh merge 102 --evidence-dir "$ev_r1" \
  >"$TMP/stale1.log" 2>&1
stale1=$?
GITHUB_ACTIONS=true GITHUB_RUN_ID="$rid_g1" GITHUB_RUN_ATTEMPT=1 \
GITHUB_REPOSITORY=acme/e2e-fixture \
  in_dir "$RUNNER" bash scripts/review-verdict.sh merge 102 --evidence-dir "$ev_r1" \
  >"$TMP/stale2.log" 2>&1
stale2=$?
GITHUB_ACTIONS=true GITHUB_RUN_ID="$rid_r2" GITHUB_RUN_ATTEMPT=1 \
GITHUB_REPOSITORY=acme/e2e-fixture \
  in_dir "$RUNNER" bash scripts/review-verdict.sh merge 102 --evidence-dir "$ev_r2" \
  >"$TMP/stale3.log" 2>&1
stale3=$?
set -e
assert_eq "$stale1" "7" \
  "AC3: verdict bound to superseded head ${head_impl:0:12} refused (head moved)"
assert_eq "$stale2" "8" \
  "AC3: verdict from a superseded review run refused (stale run evidence)"
# Tampered gate evidence must never merge, even for the live head.
cp -R "$ev_g1" "$TMP/ev-tampered"
printf 'tampered\n' >> "$TMP/ev-tampered/gate.json"
set +e
GITHUB_ACTIONS=true GITHUB_RUN_ID="$rid_g1" GITHUB_RUN_ATTEMPT=1 \
GITHUB_REPOSITORY=acme/e2e-fixture \
  in_dir "$RUNNER" bash scripts/review-verdict.sh merge 102 \
  --evidence-dir "$TMP/ev-tampered" >"$TMP/stale3.log" 2>&1
stale3=$?
set -e
assert_eq "$stale3" "6" \
  "AC3: merge refused when gate evidence changed after the review"
assert_rc 0 "AC3: merge of PR 102 bound to repaired head ${head_r2:0:12}" \
  merge_verdict "$WT2" 102 "$rid_g1" "$ev_g1"
evidence "AC3" "PR 102: 2 bounded repair rounds; fresh review run $rid_g1 on repaired head ${head_r2:0:12}; merged bound to that head"
check "AC2: T002 issue closed after repaired merge" \
  grep -q '"number":2,[^}]*"state":"CLOSED"' "$GH_STATE_DIR/state.json"
git -C "$VERIFY" fetch -q origin
git -C "$VERIFY" checkout -q -B main origin/main
check "AC3: repaired behavior merged into the target branch" \
  bash -c 'cd "$1" && out="$(bash src/req2.sh --flag 2>/dev/null || true)" && [ "$out" = "req2-edge-ok" ]' _ "$VERIFY"

# --- T003: interruption, then recovery through the same pipeline -------------
sel="$(in_dir "$RUNNER" bash scripts/agent-schedule.sh next 2>/dev/null)"
assert_eq "${sel:-}" "$I3" "AC1: T003 eligible only after T002 merged"
assert_rc 4 "AC5: interrupted run fails verification (partial work published)" \
  run_task "$I3" T003 "crash"
head_crash="$(git -C "$FX/origin/origin.git" rev-parse "refs/heads/agent/issue-$I3")"
check "AC5: interruption published the partial branch" test -n "$head_crash"
pr103="$(state_count "(s.prs.find((x) => x.headRefName === 'agent/issue-$I3') || {number:0}).number")"
assert_eq "$pr103" "103" \
  "AC5: interrupted run still produced a linked PR (artifact verification)"
evidence "AC5" "T003 interrupted after publishing ${head_crash:0:12}; verification failed, task requeued with agent-failed"

set +e
HARNESS_TASK=T003 HARNESS_MODE="" HARNESS_ISSUE=$I3 \
  in_dir "$RUNNER" bash scripts/pr-repair.sh dispatch 103 --rejected-head "$head_crash" \
  -- bash scripts/harness-impl.sh
resume_rc=$?
set -e
assert_eq "$resume_rc" "0" "AC5: recovery resumes the existing branch without redoing work"
head_resume="$(git -C "$FX/origin/origin.git" rev-parse "refs/heads/agent/issue-$I3")"
check "AC5: resumed branch keeps the partial commit (idempotent resume)" \
  git -C "$RUNNER" merge-base --is-ancestor "$head_crash" "$head_resume"
evidence "AC5" "T003 recovery resumed ${head_crash:0:12} -> ${head_resume:0:12} (partial commit preserved)"

# Duplicate dispatch for a task whose claim is held: no duplicate work.
set +e
HARNESS_TASK=T003 HARNESS_MODE="" HARNESS_ISSUE=$I3 \
  in_dir "$RUNNER" bash scripts/agent-task.sh run "$I3" --target origin/main \
  --owner "e2e-duplicate-$$" -- bash scripts/harness-impl.sh
dup_rc=$?
set -e
assert_eq "$dup_rc" "3" "AC5: duplicate agent dispatch absorbed by the claim protocol"
head_dup="$(git -C "$FX/origin/origin.git" rev-parse "refs/heads/agent/issue-$I3")"
check "AC5: duplicate dispatch created no duplicate work" test "$head_dup" = "$head_resume"

WT3="$RUNNER/.agent-work/issue-$I3"
rid3="$(next_run_id)"
res="$(review_run "$WT3" 103 APPROVE "$rid3")"
rest3="${res#* }"; head3="${rest3%% *}"; ev3="${rest3#* }"
assert_rc 0 "AC2: merge of T003 bound to reviewed head" \
  merge_verdict "$WT3" 103 "$rid3" "$ev3"
evidence "AC2" "T003: review run $rid3 on ${head3:0:12}, merged; SC-1 integration assertion green on main"

# --- queue drained -> convergence (AC4: injected missing requirement) --------
git -C "$VERIFY" fetch -q origin
git -C "$VERIFY" checkout -q -B main origin/main
check "AC1: requirement-level assertions merged (req1/req2/edge)" \
  bash -c 'test -f "$1/tests/test-req1.sh" && test -f "$1/tests/test-req2.sh" && test -f "$1/tests/test-req2-edge.sh"' _ "$VERIFY"
check "AC1: integration assertion merged (SC-1)" \
  bash -c 'test -f "$1/tests/test-integration.sh"' _ "$VERIFY"

in_dir "$VERIFY" bash scripts/spec-advance.sh on-drained "$SPEC" --json >/dev/null 2>&1 \
  && ok "AC2: drained queue dispatched convergence autonomously" \
  || bad "AC2: drained queue dispatched convergence autonomously"
assert_contains "$GH_STATE_DIR/dispatch.log" "workflow run spec-converge.yml" \
  "AC2: on-drained dispatched spec-converge.yml"

# Duplicate drained event while convergence is in flight: run-key dedupe.
GH_STATE="$GH_STATE_DIR" node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.env.GH_STATE + "/state.json", "utf8"));
  s.runs.push({ workflow: "spec-converge.yml", branch: "",
    headSha: "", status: "in_progress", id: "in-flight",
    displayTitle: "spec-converge " + process.argv[1] + " @ " + process.argv[2] });
  fs.writeFileSync(process.env.GH_STATE + "/state.json", JSON.stringify(s));
' "$SPEC" "$R1"
before="$(grep -c "workflow-run" "$GH_STATE_DIR/dispatch.log")"
in_dir "$VERIFY" bash scripts/spec-advance.sh on-drained "$SPEC" --json >/dev/null 2>&1 \
  && ok "AC5: duplicate drained event absorbed" \
  || bad "AC5: duplicate drained event absorbed"
after="$(grep -c "workflow-run" "$GH_STATE_DIR/dispatch.log")"
assert_eq "$after" "$before" "AC5: in-flight convergence run key deduped the duplicate dispatch"
GH_STATE="$GH_STATE_DIR" node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.env.GH_STATE + "/state.json", "utf8"));
  s.runs = s.runs.filter((r) => r.id !== "in-flight");
  fs.writeFileSync(process.env.GH_STATE + "/state.json", JSON.stringify(s));
'
evidence "AC5" "duplicate on-drained event while convergence in flight: no duplicate dispatch (run key)"

# Convergence round 1: REQ1/REQ2/SC-1 verified, REQ3 injected as missing.
FINDINGS1="$TMP/findings-1.jsonl"
cat > "$FINDINGS1" <<'EOF'
{"kind": "verified", "requirement": "REQ1", "summary": "requirement assertion tests/test-req1.sh passes on the integrated branch", "evidence": "tests/test-req1.sh"}
{"kind": "verified", "requirement": "REQ2", "summary": "default and edge behavior covered by tests/test-req2.sh and tests/test-req2-edge.sh", "evidence": "tests/test-req2-edge.sh"}
{"kind": "verified", "requirement": "SC-1", "summary": "integration assertion tests/test-integration.sh composes the modules", "evidence": "tests/test-integration.sh"}
{"kind": "missing", "id": "GAP-REQ3", "requirement": "REQ3", "summary": "REQ3 audit report is not implemented anywhere in the tree"}
EOF
save_artifact "$FINDINGS1" "findings-round1.jsonl"
CONV1_JSON="$(cd "$VERIFY" && bash scripts/spec-converge.sh "$SPEC" "$R1" \
  --findings "$FINDINGS1" --json 2>"$TMP/converge1.err")" \
  && ok "AC4: convergence round 1 scheduled remediation" \
  || bad "AC4: convergence round 1 scheduled remediation" "$(cat "$TMP/converge1.err")"
assert_eq "$(printf '%s' "$CONV1_JSON" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')" "remediation-scheduled" \
  "AC4: convergence status remediation-scheduled"
check "AC4: remediation issue entered the ready queue in the feature milestone" \
  grep -q '"ready-for-agent"' "$GH_STATE_DIR/state.json"
check "AC4: no completion record before remediation" \
  test ! -f "$VERIFY/specs/050-e2e/convergence/complete.json"
evidence "AC4" "injected missing REQ3: convergence scheduled remediation [050-e2e/GAP-REQ3] (issue 4)"

in_dir "$VERIFY" bash scripts/spec-advance.sh after-converge "$SPEC" "$R1" \
  --verify-status ok --json >/dev/null 2>&1 \
  && ok "AC4: after-converge returned remediation to the scheduler" \
  || bad "AC4: after-converge returned remediation to the scheduler"
assert_contains "$GH_STATE_DIR/dispatch.log" "workflow run agent-scheduler.yml" \
  "AC4: remediation re-entered the autonomous scheduler"

# Remediation task runs through the same pipeline and merges.
sel="$(in_dir "$RUNNER" bash scripts/agent-schedule.sh next 2>/dev/null)"
assert_eq "${sel:-}" "4" "AC4: scheduler picks up the remediation issue"
assert_rc 0 "AC4: remediation task completes through the unified pipeline" \
  run_task "4" REM ""
WT4="$RUNNER/.agent-work/issue-4"
rid4="$(next_run_id)"
res="$(review_run "$WT4" 104 APPROVE "$rid4")"
rest4="${res#* }"; head4="${rest4%% *}"; ev4="${rest4#* }"
assert_rc 0 "AC4: remediation merge bound to reviewed head" \
  merge_verdict "$WT4" 104 "$rid4" "$ev4"
evidence "AC4" "remediation merged on ${head4:0:12} (run $rid4); REQ3 evidence landed before completion"

# --- convergence round 2: all requirements evidenced -> verified completion --
git -C "$VERIFY" fetch -q origin
git -C "$VERIFY" checkout -q -B main origin/main
in_dir "$VERIFY" bash scripts/spec-advance.sh on-drained "$SPEC" --json >/dev/null 2>&1 \
  && ok "AC2: drained queue re-dispatched convergence" \
  || bad "AC2: drained queue re-dispatched convergence"
FINDINGS2="$TMP/findings-2.jsonl"
cat > "$FINDINGS2" <<'EOF'
{"kind": "verified", "requirement": "REQ1", "summary": "requirement assertion tests/test-req1.sh passes on the integrated branch", "evidence": "tests/test-req1.sh"}
{"kind": "verified", "requirement": "REQ2", "summary": "default and edge behavior covered by tests/test-req2.sh and tests/test-req2-edge.sh", "evidence": "tests/test-req2-edge.sh"}
{"kind": "verified", "requirement": "REQ3", "summary": "audit report asserted by tests/test-req3.sh", "evidence": "tests/test-req3.sh"}
{"kind": "verified", "requirement": "SC-1", "summary": "integration assertion tests/test-integration.sh composes REQ1-REQ3", "evidence": "tests/test-integration.sh"}
EOF
save_artifact "$FINDINGS2" "findings-round2.jsonl"
CONV2_JSON="$(cd "$VERIFY" && bash scripts/spec-converge.sh "$SPEC" "$R1" \
  --findings "$FINDINGS2" --json 2>"$TMP/converge2.err")" \
  && ok "AC2: convergence round 2 verified completion" \
  || bad "AC2: convergence round 2 verified completion" "$(cat "$TMP/converge2.err")"
assert_eq "$(printf '%s' "$CONV2_JSON" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')" "complete" \
  "AC2: convergence status complete"
check "AC2: completion record published with requirement evidence" \
  test -f "$VERIFY/specs/050-e2e/convergence/complete.json"
save_artifact "$VERIFY/specs/050-e2e/convergence/complete.json" "complete.json"
save_artifact "$VERIFY/specs/050-e2e/convergence/evidence/gate.json" "acceptance-gate.json"
COMMIT_FINAL="$(cd "$VERIFY" && git rev-parse HEAD)"
check "AC2: all four requirements carry verified evidence records" \
  bash -c 'grep -c "\"status\": \"verified\"" "$1/specs/050-e2e/convergence/complete.json" | grep -qx "4"' _ "$VERIFY"
check "AC2: completion record bound to the approved revision" \
  grep -Fq "$R1" "$VERIFY/specs/050-e2e/convergence/complete.json"
evidence "AC2" "convergence round 2: complete.json with 4/4 verified requirements @ $R1, validated commit ${COMMIT_FINAL:0:12}"

in_dir "$VERIFY" bash scripts/spec-advance.sh after-converge "$SPEC" "$R1" \
  --verify-status ok --json > "$TMP/after-converge-final.out" 2>/dev/null \
  && ok "AC2: after-converge reports the terminal state" \
  || bad "AC2: after-converge reports the terminal state"
check "AC2: terminal decision complete (no further dispatch)" \
  grep -q '"decision":"complete"' "$TMP/after-converge-final.out"
check "AC2: feature milestone closed on completion" \
  grep -q '"milestones":\[{[^}]*"state":"closed"' "$GH_STATE_DIR/state.json"

# --- the lifecycle needed exactly the autonomous dispatches -------------------
dispatched_workflows="$(sed -n 's/^workflow-run workflow run \([a-z-]*\.yml\).*/\1/p' "$GH_STATE_DIR/dispatch.log" | LC_ALL=C sort | uniq -c | awk '{print $2":"$1}')"
assert_eq "$dispatched_workflows" "agent-scheduler.yml:2
spec-converge.yml:2" \
  "AC2: exactly the autonomous dispatches happened (2 scheduler, 2 convergence)"
save_artifact "$GH_STATE_DIR/dispatch.log" "dispatch-log.txt"
evidence "AC2" "dispatch log: after-start + remediation handoff to agent-scheduler.yml; two drained-queue dispatches of spec-converge.yml; no other triggers"

# --- spec-track: the whole journey is observable (AC6) ------------------------
TRACK_JSON="$(cd "$VERIFY" && bash scripts/spec-track.sh "$SPEC" --json 2>/dev/null)" \
  && ok "AC6: spec-track reports the completed lifecycle" \
  || bad "AC6: spec-track reports the completed lifecycle"
assert_eq "$(printf '%s' "$TRACK_JSON" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')" "complete" \
  "AC6: tracked lifecycle state complete"
printf '%s\n' "$TRACK_JSON" > "$TMP/track.json"
save_artifact "$TMP/track.json" "spec-track-final.json"
evidence "AC6" "spec-track final state: complete, milestone closed, 4/4 requirements evidenced"

# ============================================================================
# PHASE B: budget exhaustion/resume, stale heads, no-progress, duplicate
# repair events (AC3/AC5) in a dedicated fixture.
# ============================================================================
FXB="$TMP/repair"
new_mock "$FXB/gh"
GH_ORIGIN="$FXB/origin/origin.git"
GH_MERGE_DIR="$FXB/mergebot"
export GH_ORIGIN GH_MERGE_DIR

make_fixture "$FXB" \
  '{"max_attempts_per_issue": 3, "max_repair_rounds": 2, "max_convergence_rounds": 3}' \
  repair
RUNNER_B="$FXB/runner"
make_branch_pr "$FXB" 90 101
make_branch_pr "$FXB" 91 102
make_branch_pr "$FXB" 92 103
evidence "AC3" "fixture B: three rejected PRs (90 stale-head, 91 budget, 92 duplicate events), max_repair_rounds=2"

# --- changed PR head: stale rejection never repairs (AC5) ----------------------
git -C "$FXB/rejected-90" fetch -q origin
git -C "$FXB/rejected-90" checkout -q -B agent/issue-90 origin/agent/issue-90
printf 'notes for feature 90\n' > "$FXB/rejected-90/docs-90.md"
git -C "$FXB/rejected-90" add -A
git -C "$FXB/rejected-90" commit -qm "docs: notes for feature 90"
git -C "$FXB/rejected-90" push -q origin "HEAD:refs/heads/agent/issue-90"
newhead90="$(git -C "$FXB/rejected-90" rev-parse HEAD)"
oldhead90="$(cat "$FXB/rejected-90-head")"

set +e
REPAIR_MODE=no-op REPAIR_ISSUE=90 \
  in_dir "$RUNNER_B" bash scripts/pr-repair.sh dispatch 101 -- bash scripts/harness-repair.sh
stale_rc=$?
set -e
assert_eq "$stale_rc" "0" "AC5: rejection for a superseded head is skipped, not repaired"
check "AC5: no repair registry entry created for the stale rejection" \
  remote_ref_absent "$RUNNER_B" "refs/agent-repairs/90"

# Explicit stale --rejected-head must be refused too.
set +e
REPAIR_MODE=no-op REPAIR_ISSUE=90 \
  bash "$RUNNER_B/scripts/pr-repair.sh" dispatch 101 --rejected-head "$oldhead90" \
  -- bash scripts/harness-repair.sh
stale2_rc=$?
set -e
assert_eq "$stale2_rc" "0" "AC5: explicit stale --rejected-head refused"
check "AC5: still no repair after explicit stale head" \
  remote_ref_absent "$RUNNER_B" "refs/agent-repairs/90"
evidence "AC5" "PR 101 head moved ${oldhead90:0:12} -> ${newhead90:0:12}; both stale rejections skipped without a repair"

# --- no-progress detection blocks unbounded repair loops (AC3) -----------------
# Freshen the recorded review so the rejection targets the live head.
freshen_review "agent/issue-90" "$newhead90"
set +e
REPAIR_MODE=no-op REPAIR_ISSUE=90 \
  in_dir "$RUNNER_B" bash scripts/pr-repair.sh dispatch 101 -- bash scripts/harness-repair.sh
noop_rc=$?
set -e
assert_eq "$noop_rc" "0" "AC3: verified repair without a head change is recorded (round 1)"
set +e
REPAIR_MODE=no-op REPAIR_ISSUE=90 \
  in_dir "$RUNNER_B" bash scripts/pr-repair.sh dispatch 101 -- bash scripts/harness-repair.sh
noprogress_rc=$?
set -e
assert_eq "$noprogress_rc" "0" "AC3: repeated failure without progress is blocked, not looped"
reg90="$(registry_json "$RUNNER_B" 90)"
check "AC3: no-progress block recorded in the registry" \
  grep -Fq '"blocked":1' <<< "${reg90:-}"
check "AC3: blocked issue carries the blocked label" \
  grep -q '"number":90,[^}]*"labels":\["agent-failed","blocked"\]' "$GH_STATE_DIR/state.json"
evidence "AC3" "PR 101: verified no-progress repair blocked the loop; registry blocked=1, issue 90 labeled blocked"

# Resume path: reset clears the block (the documented human resumption).
in_dir "$RUNNER_B" bash scripts/pr-repair.sh reset 90 > "$TMP/reset90.log" 2>&1 \
  && ok "AC5: pr-repair reset clears the blocked state" \
  || bad "AC5: pr-repair reset clears the blocked state"
check "AC5: registry cleared after reset" \
  remote_ref_absent "$RUNNER_B" "refs/agent-repairs/90"

# --- budget exhaustion then resume (AC5) ----------------------------------------
set +e
REPAIR_MODE=break REPAIR_ISSUE=91 \
  in_dir "$RUNNER_B" bash scripts/pr-repair.sh dispatch 102 -- bash scripts/harness-repair.sh
b1_rc=$?
freshen_review "agent/issue-91" "$(git -C "$FXB/origin/origin.git" rev-parse "refs/heads/agent/issue-91")"
REPAIR_MODE=break REPAIR_ISSUE=91 \
  in_dir "$RUNNER_B" bash scripts/pr-repair.sh dispatch 102 -- bash scripts/harness-repair.sh
b2_rc=$?
freshen_review "agent/issue-91" "$(git -C "$FXB/origin/origin.git" rev-parse "refs/heads/agent/issue-91")"
REPAIR_MODE=no-op REPAIR_ISSUE=91 \
  in_dir "$RUNNER_B" bash scripts/pr-repair.sh dispatch 102 -- bash scripts/harness-repair.sh
b3_rc=$?
set -e
assert_eq "$b1_rc" "4" "AC5: repair round 1 fails verification (failing CI)"
assert_eq "$b2_rc" "6" \
  "AC5: round 2 stops at the exhausted repair budget (durable rounds 2/2)"
assert_eq "$b3_rc" "0" "AC5: further events are absorbed as a terminal block"
reg91="$(registry_json "$RUNNER_B" 91)"
check "AC5: repair budget exhausted -> blocked" \
  grep -Fq '"blocked":1' <<< "${reg91:-}"
check "AC5: issue 91 carries the blocked label" \
  grep -q '"number":91,[^}]*"labels":\["agent-failed","blocked"\]' "$GH_STATE_DIR/state.json"
evidence "AC5" "issue 91: repair budget exhausted 2/2 -> budget_exhausted, then blocked (a human must review before more autonomy)"

in_dir "$RUNNER_B" bash scripts/pr-repair.sh reset 91 >/dev/null 2>&1 \
  && ok "AC5: budget block reset for resume" || bad "AC5: budget block reset for resume"
# Human resume also clears the durable repair-round counter (pr-repair reset
# only clears the registry ref and the blocked label; the budget status ref
# is the mirror the budget gate reads).
in_dir "$RUNNER_B" bash scripts/agent-budget.sh record 91 --field repair_rounds=0 >/dev/null 2>&1 \
  && ok "AC5: durable repair-round counter cleared for resume" \
  || bad "AC5: durable repair-round counter cleared for resume"
set +e
REPAIR_MODE=fix REPAIR_ISSUE=91 \
  in_dir "$RUNNER_B" bash scripts/pr-repair.sh dispatch 102 -- bash scripts/harness-repair.sh
fix_rc=$?
set -e
assert_eq "$fix_rc" "0" "AC5: resumed repair verifies green"
fixhead="$(git -C "$FXB/origin/origin.git" rev-parse "refs/heads/agent/issue-91")"
WT91="$RUNNER_B/.agent-work/issue-91"
rid91="$(next_run_id)"
res="$(review_run "$WT91" 102 APPROVE "$rid91")"
rest91="${res#* }"; head91="${rest91%% *}"; ev91="${rest91#* }"
assert_rc 0 "AC5: resumed work merged, bound to the repaired head" \
  merge_verdict "$WT91" 102 "$rid91" "$ev91"
check "AC5: merged head is the repaired head" test "$head91" = "$fixhead"
evidence "AC5" "issue 91 resumed after reset: repaired head ${fixhead:0:12} reviewed (run $rid91) and merged"

# --- duplicate repair events while a repair is in flight (AC5) ------------------
set +e
REPAIR_MODE=slow-fix REPAIR_ISSUE=92 \
  in_dir "$RUNNER_B" bash scripts/pr-repair.sh dispatch 103 -- bash scripts/harness-repair.sh &
slow_pid=$!
# Deterministic: dispatch the duplicate only once the claim is durably held.
_claims=0
while [ "$_claims" -lt 40 ]; do
  if remote_ref_exists "$RUNNER_B" "refs/agent-claims/92"; then
    break
  fi
  _claims=$((_claims + 1))
  sleep 0.5
done
REPAIR_MODE=no-op REPAIR_ISSUE=92 \
  in_dir "$FXB/runner2" bash scripts/pr-repair.sh dispatch 103 -- bash scripts/harness-repair.sh > "$TMP/dup92.log" 2>&1
dup92_rc=$?
wait "$slow_pid"
slow_rc=$?
set -e
assert_eq "$slow_rc" "0" "AC5: in-flight repair completes"
assert_eq "$dup92_rc" "0" "AC5: duplicate repair event absorbed while claim is held"
edge_commits="$(git -C "$FXB/origin/origin.git" log --format=%s "refs/heads/main..refs/heads/agent/issue-92" 2>/dev/null | grep -c "Repair reviewed defect" || true)"
assert_eq "$edge_commits" "1" "AC5: duplicate event produced no duplicate repair work"
evidence "AC5" "duplicate repair dispatch for PR 103 skipped while the claim was held; exactly one repair commit"

PATH="$ORIG_PATH"

# ============================================================================
# AC6: acceptance report (redacted ids, verdicts, evidence, artifacts)
# ============================================================================
REPORT="$REPORT_DIR/acceptance-report.md"
{
  printf '# E2E autonomous lifecycle - acceptance report (issue #48)\n\n'
  printf 'Generated by `tests/test-e2e-lifecycle.sh` in a disposable fixture\n'
  printf 'repository (`acme/e2e-fixture`); all identifiers below are fixture-local\n'
  printf 'and redacted of local paths. Run ids are the mock workflow run ids,\n'
  printf 'commit ids are fixture commit ids, verdicts are the distilled review\n'
  printf 'verdict artifacts.\n\n'
  printf -- '## AC1 fixture: approved spec, dependency chain, assertions\n\n%s\n' "$EVID_AC1"
  printf -- '## AC2 start-to-complete after one approval/start action\n\n%s\n' "$EVID_AC2"
  printf -- '## AC3 rejected review + failing CI -> bounded repair -> fresh review -> merge bound to repaired head\n\n%s\n' "$EVID_AC3"
  printf -- '## AC4 missing requirement -> remediation before completion\n\n%s\n' "$EVID_AC4"
  printf -- '## AC5 duplicates, interruption/recovery, changed heads, budget exhaustion/resume\n\n%s\n' "$EVID_AC5"
  printf -- '## AC6 saved evidence and repeatability\n\n%s' "$EVID_AC6"
  printf -- '- deterministic: the whole chain runs locally with a mocked gh boundary\n'
  printf -- '- real Actions smoke run: .github/workflows/e2e-smoke.yml (workflow_dispatch)\n\n'
  printf -- '## Artifacts\n\n'
  for f in "$REPORT_DIR"/artifacts/*; do
    [ -e "$f" ] || continue
    printf -- '- `%s`\n' "${f##*/}"
  done
} > "$REPORT"
save_artifact "$FX/gh/gh.log" "gh-boundary.log"

check "AC6: acceptance report written" test -s "$REPORT"
for ac in AC1 AC2 AC3 AC4 AC5 AC6; do
  check "AC6: report documents $ac" grep -q "## $ac" "$REPORT"
done
check "AC6: verdict artifacts saved" \
  bash -c 'ls "$1"/artifacts/verdict-run-*.json >/dev/null 2>&1' _ "$REPORT_DIR"
check "AC6: gate evidence saved" \
  bash -c 'ls "$1"/artifacts/gate-run-*.json >/dev/null 2>&1' _ "$REPORT_DIR"
check "AC6: completion record saved" test -f "$REPORT_DIR/artifacts/complete.json"
check "AC6: requirement findings saved" test -f "$REPORT_DIR/artifacts/findings-round2.jsonl"
evidence "AC6" "acceptance report + artifacts persisted under E2E_REPORT_DIR (default run-local)"

echo "report: $REPORT"

if [ "$failures" -eq 0 ]; then
  echo "all tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
