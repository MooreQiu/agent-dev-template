#!/usr/bin/env bash
# Deterministic stage transitions for approved features (issue #47).
#
# Planning, scheduling, convergence, and repair exist as separate
# entrypoints; this coordinator wires their event handoff so an approved
# feature advances through the pipeline without further routine human
# triggers. Every transition is invoked by the workflow that just finished
# a stage, decides from durable state (approval record, milestone, queue,
# in-flight runs, budgets), and dispatches the next stage via an
# authenticated workflow_dispatch:
#
#   after-start <spec> <revision>
#       Called at the end of spec-start.yml. The human approval/start
#       action durably identified the feature and approved revision, and
#       planning plus issue generation are done -- hand the new
#       ready-for-agent queue to the scheduler (AC1). GITHUB_TOKEN label
#       events do not trigger workflows, so the handoff is an explicit
#       dispatch, never a model prompt (AC3).
#
#   after-converge <spec> <revision> --verify-status <ok|blocked>
#       Called at the end of spec-converge.yml after a validated verify
#       outcome. A completion record publishes the terminal state; a
#       blocked outcome is a documented resumable waiting-on-human state;
#       otherwise remediation issues re-enter the queue and the transition
#       returns them to the same scheduler (AC2/AC5).
#
#   on-drained [<spec>]
#       Called by the scheduler's advance job when no eligible task
#       remains. Probes approved features (all of them when no spec is
#       given) and invokes convergence for each drained one: milestone
#       still open, no paused/cancelled blocker, no in-flight convergence
#       run for the same stage key (idempotent run key, AC4), queue
#       drained, and within the project-wide convergence budget (AC5).
#
# Dispatch authentication: workflow_dispatch triggered with the caller's
# GITHUB_TOKEN (permissions: actions: write) is the documented exception
# that still creates a downstream workflow run; GitHub App installation
# tokens may lack actions:write, so the dispatch prefers GITHUB_TOKEN
# while all other gh calls keep the ambient token. See docs/SPEC_ADVANCE.md.
#
# Exit codes: 0 = transition decided (dispatched or deliberately skipped),
#             1 = gate failure (fail closed), 2 = usage error.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"

log() { printf '%s\n' "$*" >&2; }
die() { # die <exit-code> <message...>
  code=$1; shift
  printf 'ERROR: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/spec-advance.sh after-start <spec-path> <approved-revision> [--json]
  scripts/spec-advance.sh after-converge <spec-path> <approved-revision> \
      --verify-status <ok|blocked> [--json]
  scripts/spec-advance.sh on-drained [<spec-path>] [--json]

Transitions an approved feature between pipeline stages via authenticated
workflow dispatches. Contract, run keys, and resumable states:
docs/SPEC_ADVANCE.md.
EOF
}

TAB="$(printf '\t')"
TRANSITION=""
JSON=0
SUMMARY=""

sanitize() { printf '%s' "$1" | tr -d '"\\'; }

summary_line() { # summary_line <markdown line>
  SUMMARY="${SUMMARY}$1
"
}

publish_summary() { # repository-native stage summary (Actions step summary)
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$SUMMARY" >> "$GITHUB_STEP_SUMMARY"
  fi
}

emit() { # emit <feature> <spec> <revision> <decision> <next> <dispatched> <reason> [budget]
  f_feature=$1; f_spec=$2; f_rev=$3; f_decision=$4; f_next=$5; f_disp=$6; f_reason=$7
  f_budget="${8:-0}"
  if [ "$JSON" -eq 1 ]; then
    printf '{"feature":"%s","spec":"%s","revision":"%s","transition":"%s","decision":"%s","next":"%s","dispatched":"%s","reason":"%s","budget":%s}\n' \
      "$(sanitize "$f_feature")" "$f_spec" "$f_rev" "$TRANSITION" \
      "$f_decision" "$f_next" "$f_disp" "$(sanitize "$f_reason")" "$f_budget"
  else
    printf 'spec-advance: feature=%s transition=%s decision=%s next=%s\n' \
      "$f_feature" "$TRANSITION" "$f_decision" "$f_next"
    [ -z "$f_disp" ] || printf '  dispatched: %s\n' "$f_disp"
    [ -z "$f_reason" ] || printf '  reason: %s\n' "$f_reason"
  fi
  summary_line "## Pipeline stage advance (issue #47)"
  summary_line ""
  summary_line "- Feature: $f_feature ($f_spec @ ${f_rev:0:12})"
  summary_line "- Transition: $TRANSITION"
  summary_line "- Decision: $f_decision${f_disp:+, dispatched \`$f_disp\`}"
  summary_line "- Next action: $f_next"
  [ -z "$f_reason" ] || summary_line "- Evidence: $f_reason"
  summary_line ""
}

# --- dispatch: the authenticated event handoff (AC3) --------------------------
dispatch_workflow() { # dispatch_workflow <workflow-file> [gh args...]
  wf=$1; shift
  # workflow_dispatch events created with the repository GITHUB_TOKEN are
  # the documented exception that actually starts a downstream run; an
  # installation token without actions:write would only fail the handoff.
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    GH_TOKEN="$GITHUB_TOKEN" gh workflow run "$wf" "$@"
  else
    gh workflow run "$wf" "$@"
  fi
}

# --- shared gates ---------------------------------------------------------------
SPEC=""
FEATURE=""
FEATURE_DIR=""

parse_spec_path() { # parse_spec_path <spec-path> (die on shape errors)
  SPEC=$1
  case "$SPEC" in
    /*|../*|*/../*|*/..|*\ **) die 2 "spec path must be relative to the repository root: $SPEC" ;;
  esac
  case "$SPEC" in
    */*) ;;
    *) die 2 "spec path must live in a feature directory: specs/<feature>/spec.md (got $SPEC)" ;;
  esac
  [ -f "$REPO_ROOT/$SPEC" ] || die 1 "spec not found: $SPEC"
  FEATURE_DIR="${SPEC%/*}"
  FEATURE="${FEATURE_DIR##*/}"
  [ -n "$FEATURE" ] && [ "$FEATURE" != "specs" ] \
    || die 1 "spec must live in a feature directory: $SPEC (expected specs/<feature>/spec.md)"
}

APPROVED_BY=""
approved_revision() { # approved_revision <revision> -> dies unless every
  # approval gate holds; sets SHA and APPROVED_BY (same contract as
  # spec-start.sh/spec-converge.sh: the approval record is the immutable anchor)
  REVISION=$1
  SHA="$(git rev-parse --verify --quiet "$REVISION^{commit}")" \
    || die 1 "unknown revision: $REVISION"
  BLOB="$(git rev-parse --verify --quiet "$SHA:$SPEC")" \
    || die 1 "approved revision $SHA does not contain $SPEC"
  CURRENT="$(git hash-object "$SPEC")"
  [ "$CURRENT" = "$BLOB" ] \
    || die 1 "stale approval: $SPEC changed since approved revision $SHA; approved requirements are never silently replaced -- request re-approval"
  APPROVAL="$FEATURE_DIR/approval.json"
  [ -f "$APPROVAL" ] \
    || die 1 "missing approval record: $APPROVAL (see docs/SPEC_START.md)"
  approved_rev="$(sed -n 's/.*"revision"[: ]*"\([0-9a-fA-F]*\)".*/\1/p' "$APPROVAL" | sed -n 1p)"
  APPROVED_BY="$(sed -n 's/.*"approved_by"[: ]*"\([^"]*\)".*/\1/p' "$APPROVAL" | sed -n 1p)"
  [ -n "$APPROVED_BY" ] \
    || die 1 "approval record $APPROVAL has no approved_by; a human must approve the spec"
  case "$SHA" in
    "$approved_rev") ;;
    *) die 1 "approval revision mismatch: record says '${approved_rev:-<empty>}', requested $SHA; approval is immutable" ;;
  esac
}

# on-drained re-checks the same gates without dying: one unready feature
# must not abort the sweep over the others. Sets SHA on success and
# APPROVAL_ERR on failure (no subshells: assignments must survive the call).
APPROVAL_ERR=""
approval_error() { # approval_error <spec> <revision>
  APPROVAL_ERR=""
  _spec=$1; _rev=$2
  _sha="$(git rev-parse --verify --quiet "$_rev^{commit}" 2>/dev/null)" || {
    APPROVAL_ERR="unknown revision $_rev"; return; }
  _blob="$(git rev-parse --verify --quiet "$_sha:$_spec" 2>/dev/null)" || {
    APPROVAL_ERR="approved revision $_sha does not contain $_spec"; return; }
  _current="$(git hash-object "$_spec" 2>/dev/null)" || _current=""
  [ "$_current" = "$_blob" ] || {
    APPROVAL_ERR="stale approval: $_spec changed since $_sha; request re-approval"; return; }
  _approval="${_spec%/*}/approval.json"
  if [ ! -f "$_approval" ]; then
    APPROVAL_ERR="missing approval record $_approval"; return
  fi
  _arev="$(sed -n 's/.*"revision"[: ]*"\([0-9a-fA-F]*\)".*/\1/p' "$_approval" | sed -n 1p)"
  _aby="$(sed -n 's/.*"approved_by"[: ]*"\([^"]*\)".*/\1/p' "$_approval" | sed -n 1p)"
  if [ -z "$_aby" ]; then APPROVAL_ERR="approval record $_approval has no approved_by"; return; fi
  case "$_sha" in
    "$_arev") ;;
    *) APPROVAL_ERR="approval revision mismatch (record ${_arev:-<empty>}, requested $_sha)"; return ;;
  esac
  SHA=$_sha
}

# --- argument parsing -----------------------------------------------------------
COMMAND="${1:-}"
[ -n "$COMMAND" ] || { usage; exit 2; }
shift

SPEC_ARG=""
REVISION_ARG=""
VERIFY_STATUS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --verify-status)
      [ $# -ge 2 ] || { usage; die 2 "--verify-status needs a value"; }
      VERIFY_STATUS=$2; shift
      ;;
    -h|--help) usage; exit 0 ;;
    -*)
      case "$1" in
        --verify-status=*) VERIFY_STATUS="${1#--verify-status=}" ;;
        *) usage; die 2 "unknown option: $1" ;;
      esac
      ;;
    *)
      if [ -z "$SPEC_ARG" ]; then SPEC_ARG=$1
      elif [ -z "$REVISION_ARG" ]; then REVISION_ARG=$1
      else usage; die 2 "unexpected argument: $1"
      fi
      ;;
  esac
  shift
done

cd "$REPO_ROOT" || die 1 "cannot enter repository root: $REPO_ROOT"
command -v gh >/dev/null 2>&1 || die 1 "gh is required for stage transitions (not found in PATH)"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
  || die 1 "gh repo view failed; check authentication"

case "$COMMAND" in
  after-start|after-converge)
    [ -n "$SPEC_ARG" ] && [ -n "$REVISION_ARG" ] || { usage; exit 2; }
    ;;
  on-drained)
    [ -n "$REVISION_ARG" ] && { usage; exit 2; }
    ;;
  *) usage; exit 2 ;;
esac
case "$COMMAND:$VERIFY_STATUS" in
  after-converge:ok|after-converge:blocked) ;;
  after-converge:*) { usage; die 2 "--verify-status must be ok or blocked (got '${VERIFY_STATUS:-<empty>}')"; } ;;
esac

TRANSITION=$COMMAND

# ============================================================================
# after-start: planning and issue generation done -> schedule the new queue
# ============================================================================
if [ "$COMMAND" = after-start ]; then
  parse_spec_path "$SPEC_ARG"
  approved_revision "$REVISION_ARG"
  dispatch_workflow "agent-scheduler.yml" --repo "$repo" \
    || die 1 "workflow_dispatch of agent-scheduler.yml failed; the queue handoff did not happen"
  emit "$FEATURE" "$SPEC" "$SHA" dispatch scheduling "agent-scheduler.yml" \
    "approval $APPROVED_BY @ ${SHA:0:12}; planning and issue generation complete (spec-start.sh); scheduling is autonomous" 0
  publish_summary
  exit 0
fi

# ============================================================================
# after-converge: publish completion, hold on blockers, or return remediation
# to the same scheduler
# ============================================================================
if [ "$COMMAND" = after-converge ]; then
  parse_spec_path "$SPEC_ARG"
  approved_revision "$REVISION_ARG"
  if [ "$VERIFY_STATUS" = blocked ]; then
    # Blocked is resumable: a human resolves the blocked reports (or raises
    # the budget) and the next drained-queue event or manual converge reruns.
    emit "$FEATURE" "$SPEC" "$SHA" blocked human-decision "" \
      "convergence reported blocked (unresolved requirements or exhausted convergence budget); a human decision resumes the pipeline" 0
    publish_summary
    exit 0
  fi
  if [ -f "$FEATURE_DIR/convergence/complete.json" ]; then
    emit "$FEATURE" "$SPEC" "$SHA" complete none "" \
      "completion record $FEATURE_DIR/convergence/complete.json published by spec-converge.sh; feature is verified complete" 0
    publish_summary
    exit 0
  fi
  dispatch_workflow "agent-scheduler.yml" --repo "$repo" \
    || die 1 "workflow_dispatch of agent-scheduler.yml failed; remediation issues would not be scheduled"
  emit "$FEATURE" "$SPEC" "$SHA" dispatch scheduling "agent-scheduler.yml" \
    "no completion record: remediation work re-entered the queue; returning it to the same scheduler" 0
  publish_summary
  exit 0
fi

# ============================================================================
# on-drained: invoke convergence for every approved feature whose queue drained
# ============================================================================

convergence_budget() { # project-wide convergence policy (fail closed)
  budget="$("$SELF_DIR/agent-budget.sh" limit max_convergence_rounds)" \
    || die 1 "cannot read max_convergence_rounds from the project budget (.agent/budgets.json); refusing to advance unbounded"
  case "$budget" in
    ''|*[!0-9]*|0) die 1 "project budget max_convergence_rounds must be a positive integer (got '$budget')" ;;
  esac
}

feature_paused_or_cancelled() { # human control labels hold the transition
  gh issue list --milestone "$FEATURE" --state open \
    --json number,labels --limit 1000 \
    --jq '.[] | [.number, ([.labels[].name] | join(","))] | @tsv' > "$WORK/control.tsv" 2>/dev/null \
    || return 1
  grep -Eq '(^|,|'"$TAB"')agent-(paused|cancelled)(,|'"$TAB"'|$)' "$WORK/control.tsv"
}

control_label_of() {
  if grep -q 'agent-cancelled' "$WORK/control.tsv"; then printf 'agent-cancelled'
  else printf 'agent-paused'; fi
}

convergence_in_flight() { # idempotent run key: one convergence per stage key
  key="spec-converge $SPEC @ $SHA"
  gh run list --workflow "spec-converge.yml" --json displayTitle,status \
    --limit 100 --jq '.[] | [.displayTitle, .status] | @tsv' > "$WORK/runs.tsv" 2>/dev/null
  in_flight=0
  while IFS="$TAB" read -r title status; do
    [ "$title" = "$key" ] || continue
    case "$status" in
      queued|in_progress) in_flight=1; break ;;
    esac
  done < "$WORK/runs.tsv"
  [ "$in_flight" -eq 0 ]
}

advance_feature() { # advance_feature <spec-path> [revision] -> 0 dispatched, 1 skipped
  parse_spec_path "$1"
  revision="$2"
  if [ -z "$revision" ]; then
    # The durable approval record carries the revision.
    approval_file="$FEATURE_DIR/approval.json"
    if [ ! -f "$approval_file" ]; then
      emit "$FEATURE" "$SPEC" unknown skip none "" "missing approval record $approval_file"
      return 1
    fi
    revision="$(sed -n 's/.*"revision"[: ]*"\([0-9a-fA-F]*\)".*/\1/p' "$approval_file" | sed -n 1p)"
  fi
  err=""
  approval_error "$SPEC" "$revision"
  err="$APPROVAL_ERR"
  if [ -n "$err" ]; then
    emit "$FEATURE" "$SPEC" "${revision:-unknown}" skip none "" "$err"
    return 1
  fi

  ms_state="$(gh api "repos/$repo/milestones" \
    --jq ".[] | select(.title == \"$FEATURE\") | .state" 2>/dev/null || true)"
  if [ "$ms_state" = closed ]; then
    emit "$FEATURE" "$SPEC" "$SHA" skip none "" "milestone $FEATURE is closed: the feature is verified complete (terminal stage)"
    return 1
  fi

  if feature_paused_or_cancelled; then
    emit "$FEATURE" "$SPEC" "$SHA" skip none "" "a human control ($(control_label_of)) holds this feature; remove the label to resume the transition"
    return 1
  fi

  if ! convergence_in_flight; then
    emit "$FEATURE" "$SPEC" "$SHA" skip none "" "convergence is already in flight for the stage key $FEATURE @ ${SHA:0:12} (run key dedupe)"
    return 1
  fi

  pre_out="$(bash "$SELF_DIR/spec-converge-precheck.sh" "$SPEC" "$SHA" --precheck --json 2>/dev/null)"
  pre_rc=$?
  outcome="$(printf '%s\n' "$pre_out" | awk -F= '/^outcome=/{v=$2} END{print v}')"
  case "$pre_rc:$outcome" in
    0:ready) ;;
    0:deferred|3:*)
      emit "$FEATURE" "$SPEC" "$SHA" skip none "" "task queue not drained; convergence stays deferred until the remaining work closes"
      return 1 ;;
    1:*)
      emit "$FEATURE" "$SPEC" "$SHA" skip none "" "feature is not ready for convergence (planning artifacts or approval gates unmet); see the converge precheck log"
      return 1 ;;
    *)
      die "$pre_rc" "convergence precheck failed unexpectedly (rc $pre_rc); failing closed instead of advancing" ;;
  esac

  convergence_budget
  dispatch_workflow "spec-converge.yml" --repo "$repo" \
    -f "spec=$SPEC" -f "revision=$SHA" -f "budget=$budget" \
    || die 1 "workflow_dispatch of spec-converge.yml failed; convergence did not start"
  emit "$FEATURE" "$SPEC" "$SHA" dispatch convergence "spec-converge.yml" \
    "queue drained (precheck outcome=ready); run key spec-converge $SPEC @ ${SHA:0:12}; budget=$budget (max_convergence_rounds)" "$budget"
  return 0
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spec-advance.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$SPEC_ARG" ]; then
  advance_feature "$SPEC_ARG" ""
  publish_summary
  exit 0
fi

# Discovery: every feature with a committed approval record is a candidate.
candidates="$(git ls-files 'specs/*/approval.json' | sed 's#/approval.json$##' | LC_ALL=C sort)"
if [ -z "$candidates" ]; then
  log "no approved features found (no specs/*/approval.json in git)"
  exit 0
fi
for dir in $candidates; do
  advance_feature "$dir/spec.md" ""
done
publish_summary
exit 0
