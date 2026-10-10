#!/usr/bin/env bash
# Read-only tracker for autonomous development of one approved spec, from the
# human approval to verified completion (issue #24). Aggregates the durable
# artifacts the pipeline already produces (approval.json, plan.md, tasks.md,
# the issue queue, convergence records) into one state with an explicit
# next action, so normal execution needs no human supervision while genuine
# blockers surface as a resumable waiting-on-human state. See
# docs/SPEC_TRACK.md for the state machine and the status policy.
#
# Usage:
#   scripts/spec-track.sh <spec-path> [--json]
#
# <spec-path>  spec file relative to the repository root, e.g.
#              specs/016-demo/spec.md
# --json       print a single machine-readable JSON status on stdout
#
# The tracker never creates, edits, or closes anything: it only reads gh
# (issue list, milestone state) and the local worktree, so running it twice
# is always side-effect free.
#
# Exit codes: 0 = status computed (autonomous next action or complete),
#             1 = gate/validation failure, 2 = usage error,
#             4 = waiting on a human (approval or blocked resolution).
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
Usage: scripts/spec-track.sh <spec-path> [--json]
Tracks autonomous development of one feature spec from the human approval to
verified completion. Read-only: reports the pipeline state, whether the run
can proceed autonomously, and the next action; it never creates or mutates
anything (docs/SPEC_TRACK.md).
Options:
  --json  print a single machine-readable JSON status on stdout
EOF
}

SPEC=""
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json)     JSON=1 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         usage; die 2 "unknown option: $1" ;;
    *)
      if [ -z "$SPEC" ]; then SPEC=$1
      else usage; die 2 "unexpected argument: $1"
      fi
      ;;
  esac
  shift
done
[ -n "$SPEC" ] || { usage; exit 2; }

# --- path gates (same contract as spec-start.sh / spec-converge.sh) ----------
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

cd "$REPO_ROOT" || die 1 "cannot enter repository root: $REPO_ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spec-track.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- counters reported in every state ----------------------------------------
TASKS_TOTAL=0
TASKS_DONE=0
UNSCHEDULED=0
OPEN_ISSUES=0
BLOCKED_ISSUES=0
REQS_TOTAL=0
REQS_EVIDENCED=0
MILESTONE=""
REVISION=""
APPROVAL_LINE="not checked"
COMPLETION_LINE="not checked"
WARN_JSON=""
WARN_PLAIN=""

warn() { # warn <message without double quotes>
  WARN_JSON="$WARN_JSON\"$1\","
  WARN_PLAIN="${WARN_PLAIN:+$WARN_PLAIN; }$1"
}

emit() { # emit <status> <autonomous 0|1> <next> <exit-code>
  st=$1; au=$2; nx=$3; ex=$4
  if [ "$au" = 1 ]; then au_str=true; else au_str=false; fi
  if [ "$JSON" -eq 1 ]; then
    printf '{"feature":"%s","spec":"%s","revision":"%s","status":"%s","autonomous":%s,"next":"%s","tasks_total":%d,"tasks_done":%d,"unscheduled_tasks":%d,"open_issues":%d,"blocked_issues":%d,"requirements_total":%d,"requirements_evidenced":%d,"milestone":"%s","warnings":[%s]}\n' \
      "$FEATURE" "$SPEC" "$REVISION" "$st" "$au_str" "$nx" \
      "$TASKS_TOTAL" "$TASKS_DONE" "$UNSCHEDULED" \
      "$OPEN_ISSUES" "$BLOCKED_ISSUES" \
      "$REQS_TOTAL" "$REQS_EVIDENCED" "$MILESTONE" "${WARN_JSON%,}"
  else
    printf 'spec-track: feature=%s spec=%s status=%s\n' "$FEATURE" "$SPEC" "$st"
    printf '  approval: %s\n' "$APPROVAL_LINE"
    printf '  planning: %s task(s), %s done, %s unscheduled\n' \
      "$TASKS_TOTAL" "$TASKS_DONE" "$UNSCHEDULED"
    printf '  queue: %s open, %s blocked\n' "$OPEN_ISSUES" "$BLOCKED_ISSUES"
    printf '  completion: %s\n' "$COMPLETION_LINE"
    [ -z "$WARN_PLAIN" ] || printf '  warnings: %s\n' "$WARN_PLAIN"
    printf 'summary: feature=%s status=%s autonomous=%s next=%s\n' \
      "$FEATURE" "$st" "$au_str" "$nx"
  fi
  exit "$ex"
}

# --- requirement tokens from the spec (same recognizer as spec-converge.sh) --
grep -oE '(FR|SC)-[0-9]+|REQ[0-9]+' "$SPEC" | sort -u > "$WORK/reqs" || true
REQS_TOTAL=$(wc -l < "$WORK/reqs" | tr -d ' ')

# --- human gate: the approval record (read-only check, never an error) -------
APPROVAL="$FEATURE_DIR/approval.json"
approval_reason=""
approved_rev=""
approved_by=""
if [ ! -f "$APPROVAL" ]; then
  approval_reason="no approval record at $APPROVAL -- a human must approve the spec (docs/SPEC_START.md)"
else
  approved_rev="$(sed -n 's/.*"revision"[: ]*"\([0-9a-fA-F]*\)".*/\1/p' "$APPROVAL" | sed -n 1p)"
  approved_by="$(sed -n 's/.*"approved_by"[: ]*"\([^"]*\)".*/\1/p' "$APPROVAL" | sed -n 1p)"
  if [ -z "$approved_rev" ]; then
    approval_reason="approval record $APPROVAL has no revision; a human must record a valid approval"
    REVISION=""
  elif [ -z "$approved_by" ]; then
    approval_reason="approval record $APPROVAL has no approved_by; a human must approve the spec"
    REVISION="$approved_rev"
  else
    SHA="$(git rev-parse --verify --quiet "$approved_rev^{commit}")" \
      || die 1 "unknown revision in approval record: $approved_rev"
    BLOB="$(git rev-parse --verify --quiet "$SHA:$SPEC")" \
      || die 1 "approved revision $SHA does not contain $SPEC"
    REVISION="$SHA"
    CURRENT="$(git hash-object "$SPEC")"
    if [ "$CURRENT" != "$BLOB" ]; then
      approval_reason="stale approval: $SPEC changed since approved revision $SHA; approved requirements are never silently replaced -- request re-approval"
    fi
  fi
fi
if [ -n "$approval_reason" ]; then
  log "$approval_reason"
  APPROVAL_LINE="$approval_reason"
  emit awaiting-approval 0 approve 4
fi
APPROVAL_LINE="approved by $approved_by @ $SHA"
log "approved spec ok: $SPEC @ $SHA (approved by $approved_by)"

# --- planning prerequisites ---------------------------------------------------
missing=""
[ -f "$FEATURE_DIR/plan.md" ] || missing="plan.md"
[ -f "$FEATURE_DIR/tasks.md" ] || missing="${missing:+$missing, }tasks.md"
if [ -n "$missing" ]; then
  log "planning prerequisites missing: $missing (autonomous planning per docs/SPEC_START.md)"
  emit planning 1 plan 0
fi

# --- parse tasks (bash 3.2 safe; same line format as spec-start.sh) ----------
TASK_IDS=""
parse_tasks() {
  while IFS= read -r line; do
    rest=""
    case "$line" in
      "- [ ] T"[0-9]*) rest="${line#'- [ ] '}"; state="todo" ;;
      "- [x] T"[0-9]*) rest="${line#'- [x] '}"; state="done" ;;
      "- [X] T"[0-9]*) rest="${line#'- [X] '}"; state="done" ;;
      *) continue ;;
    esac
    id="${rest%% *}"
    case " $TASK_IDS " in
      *" $id "*) die 1 "duplicate task id in $FEATURE_DIR/tasks.md: $id" ;;
    esac
    TASK_IDS="$TASK_IDS $id"
    TASKS_TOTAL=$((TASKS_TOTAL + 1))
    if [ "$state" = done ]; then
      TASKS_DONE=$((TASKS_DONE + 1))
      printf 'done\n' > "$WORK/$id.state"
    else
      printf 'todo\n' > "$WORK/$id.state"
    fi
  done < "$FEATURE_DIR/tasks.md"
}
parse_tasks
[ -n "$TASK_IDS" ] || die 1 "no tasks found in $FEATURE_DIR/tasks.md (expected lines like '- [ ] T001 ...')"

# --- remote queue state via the plain gh CLI (read-only) ----------------------
command -v gh >/dev/null 2>&1 || die 1 "gh is required for queue tracking (not found in PATH)"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
  || die 1 "gh repo view failed; check authentication"

gh issue list --milestone "$FEATURE" --state open \
  --json number,title,labels --limit 1000 \
  --jq '.[] | [.number, .title, (([.labels[].name] | index("blocked")) != null)] | @tsv' \
  > "$WORK/open.tsv" || die 1 "gh issue list failed; check authentication"
OPEN_ISSUES=$(awk -F'\t' '$3 != "true" { c++ } END { print c + 0 }' "$WORK/open.tsv")
BLOCKED_ISSUES=$(awk -F'\t' '$3 == "true" { c++ } END { print c + 0 }' "$WORK/open.tsv")
while IFS="$(printf '\t')" read -r num title is_blocked; do
  [ "$is_blocked" = true ] || continue
  [ -n "$num" ] || continue
  log "blocked work waits on a human: #$num $title"
done < "$WORK/open.tsv"

gh issue list --state all --json number,title,state --limit 1000 \
  --jq '.[] | [.number, .title, .state] | @tsv' > "$WORK/existing.tsv" \
  || die 1 "gh issue list failed; check authentication"

# Unchecked tasks that do not have an issue yet (identity prefix match).
for id in $TASK_IDS; do
  [ "$(cat "$WORK/$id.state")" = done ] && continue
  if ! awk -F'\t' -v p="[$FEATURE/$id]" \
      'index($2, p) == 1 { found = 1; exit } END { exit !found }' "$WORK/existing.tsv"; then
    UNSCHEDULED=$((UNSCHEDULED + 1))
  fi
done

# --- state decision -----------------------------------------------------------
if [ "$OPEN_ISSUES" -gt 0 ]; then
  log "$OPEN_ISSUES open issue(s) in milestone $FEATURE; autonomous work continues"
  emit in-progress 1 sweep 0
fi
if [ "$BLOCKED_ISSUES" -gt 0 ]; then
  log "$BLOCKED_ISSUES blocked report(s) in milestone $FEATURE; scheduling resumes after a human decision"
  emit blocked 0 human-decision 4
fi
if [ "$UNSCHEDULED" -gt 0 ]; then
  log "$UNSCHEDULED unchecked task(s) have no issue yet; run scripts/spec-start.sh"
  emit scheduling 1 generate-issues 0
fi

# --- queue drained: verify the completion record ------------------------------
COMPLETE="$FEATURE_DIR/convergence/complete.json"
if [ ! -f "$COMPLETE" ]; then
  COMPLETION_LINE="not recorded"
  log "queue drained; verify completion with scripts/spec-converge.sh"
  emit converging 1 converge 0
fi

INVALID=0
c_status="$(sed -n 's/^  "status": "\(.*\)",$/\1/p' "$COMPLETE" | sed -n 1p)"
c_acceptance="$(sed -n 's/^  "acceptance": "\(.*\)",$/\1/p' "$COMPLETE" | sed -n 1p)"
if [ "$c_status" != "complete" ]; then
  warn "completion record status is not complete"
  INVALID=1
fi
if [ "$c_acceptance" != "pass" ]; then
  warn "completion record acceptance is not pass"
  INVALID=1
fi
# Issue #45: every approved requirement needs a verified evidence record
# naming the verification method/result, an existing evidence location, the
# approved spec revision, and the validated code commit. Generic integration
# evidence, missing/stale commits, or mismatched revisions reject the record
# and return the feature to convergence.
while IFS= read -r req; do
  [ -n "$req" ] || continue
  entry="$(sed -n "/\"id\": \"$req\"/p" "$COMPLETE" | sed -n 1p)"
  if [ -z "$entry" ]; then
    warn "requirement $req has no evidence record in the completion record"
    INVALID=1
    continue
  fi
  r_status="$(printf '%s\n' "$entry" | sed -n 's/.*"status": "\([^"]*\)".*/\1/p')"
  r_method="$(printf '%s\n' "$entry" | sed -n 's/.*"method": "\([^"]*\)".*/\1/p')"
  r_evidence="$(printf '%s\n' "$entry" | sed -n 's/.*"evidence": "\([^"]*\)".*/\1/p')"
  r_revision="$(printf '%s\n' "$entry" | sed -n 's/.*"revision": "\([^"]*\)".*/\1/p')"
  r_commit="$(printf '%s\n' "$entry" | sed -n 's/.*"commit": "\([^"]*\)".*/\1/p')"
  valid=1
  if [ "$r_status" != "verified" ]; then
    warn "requirement $req evidence is not a verified record"
    valid=0
  fi
  if [ -z "$r_method" ]; then
    warn "requirement $req evidence has no verification method"
    valid=0
  fi
  case "$r_evidence" in
    ''|/*|../*|*/../*|*/..)
      warn "requirement $req evidence location is malformed"
      valid=0
      ;;
    *)
      [ -e "$r_evidence" ] || {
        warn "requirement $req evidence location does not exist"
        valid=0
      } ;;
  esac
  if [ "$r_revision" != "$SHA" ]; then
    warn "requirement $req evidence is bound to a different spec revision than the approval"
    valid=0
  fi
  if [ -z "$r_commit" ] \
      || ! git rev-parse --verify --quiet "$r_commit^{commit}" >/dev/null 2>&1; then
    warn "requirement $req evidence has no valid code commit"
    valid=0
  elif ! git merge-base --is-ancestor "$r_commit" HEAD >/dev/null 2>&1; then
    warn "requirement $req evidence commit is not in the current history (stale)"
    valid=0
  fi
  if [ "$valid" -eq 1 ]; then
    REQS_EVIDENCED=$((REQS_EVIDENCED + 1))
  else
    INVALID=1
  fi
done < "$WORK/reqs"

# Remote-visible status (best effort; the record is the source of truth).
ms_state="$(gh api "repos/$repo/milestones" \
  --jq ".[] | select(.title == \"$FEATURE\") | .state" 2>/dev/null || true)"
case "$ms_state" in
  open)   MILESTONE=open;   warn "feature milestone is still open" ;;
  closed) MILESTONE=closed ;;
  *)      MILESTONE=missing; log "milestone $FEATURE not found; completion recorded locally only" ;;
esac

if [ "$INVALID" -eq 0 ]; then
  COMPLETION_LINE="recorded: $REQS_EVIDENCED/$REQS_TOTAL requirement(s) evidenced, acceptance pass"
  log "verified completion: $REQS_EVIDENCED/$REQS_TOTAL requirement(s) evidenced"
  emit complete 0 none 0
fi
COMPLETION_LINE="record rejected (see warnings)"
log "completion record rejected; rerun convergence (scripts/spec-converge.sh)"
emit converging 1 converge 0
