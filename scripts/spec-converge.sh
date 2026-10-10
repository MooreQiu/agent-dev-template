#!/usr/bin/env bash
# Verify project completion against the approved specification and schedule
# remaining work (issue #21). See docs/SPEC_CONVERGE.md for the findings
# contract, the convergence budget, and the status policy.
#
# Usage:
#   scripts/spec-converge.sh <spec-path> <approved-revision> [options]
#
# <spec-path>         spec file relative to the repository root, e.g.
#                     specs/016-demo/spec.md
# <approved-revision> immutable commit SHA the human approved
# --findings FILE     convergence findings as JSON Lines (schema in
#                     docs/SPEC_CONVERGE.md); gap lines become deduplicated
#                     remediation issues, verified lines become
#                     requirement-to-evidence traceability
# --budget N          max remediation attempts per finding (default 2)
# --precheck          only validate the gates and the task-queue drainage
# --dry-run           validate the gates and the findings contract; never
#                     talks to gh and never runs acceptance
# --json              print a single machine-readable JSON summary on stdout
#
# Statuses (JSON "status"):
#   complete               no gaps remain, integrated acceptance passed, and
#                          every approved requirement has a verified evidence
#                          record (issue #45)
#   remediation-scheduled  deduplicated remediation issues entered the queue
#   blocked                unresolved requirements are reported as blocked
#
# Exit codes: 0 = ok (complete or remediation-scheduled),
#             1 = gate/validation failure, 2 = usage error,
#             3 = task queue not drained (retry later), 4 = blocked.
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
Usage: scripts/spec-converge.sh <spec-path> <approved-revision> [options]
Verifies project completion against the approved spec after the task queue
drains. Gates reuse the spec-start approval record (specs/<feature>/
approval.json); findings come from the converge agent as JSON Lines; see
docs/SPEC_CONVERGE.md.
Options:
  --findings FILE  convergence findings (JSON Lines)
  --budget N       max remediation attempts per finding (default 2)
  --precheck       gates + queue drainage only
  --dry-run        validate inputs only; no gh, no acceptance run
  --json           single-line JSON summary on stdout
EOF
}

SPEC=""
REVISION=""
FINDINGS=""
BUDGET=2
PRECHECK=0
DRY_RUN=0
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --precheck)  PRECHECK=1 ;;
    --json)      JSON=1 ;;
    --findings)
      [ $# -ge 2 ] || { usage; die 2 "--findings needs a file argument"; }
      FINDINGS=$2; shift
      ;;
    --budget)
      [ $# -ge 2 ] || { usage; die 2 "--budget needs a number argument"; }
      BUDGET=$2; shift
      ;;
    -h|--help) usage; exit 0 ;;
    -*)         usage; die 2 "unknown option: $1" ;;
    *)
      if [ -z "$SPEC" ]; then SPEC=$1
      elif [ -z "$REVISION" ]; then REVISION=$1
      else usage; die 2 "unexpected argument: $1"
      fi
      ;;
  esac
  shift
done
[ -n "$SPEC" ] && [ -n "$REVISION" ] || { usage; exit 2; }
case "$BUDGET" in
  ''|*[!0-9]*|0) usage; die 2 "budget must be a positive integer (got '$BUDGET')" ;;
esac
# Resolve the findings path against the invocation directory before any cd.
if [ -n "$FINDINGS" ]; then
  case "$FINDINGS" in
    /*) ;;
    *) FINDINGS="$(pwd)/$FINDINGS" ;;
  esac
fi

# --- gates 1-5: identical contract to spec-start.sh (duplicated on purpose;
# refactoring spec-start.sh is outside issue #21 scope). ----------------------
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

SHA="$(git rev-parse --verify --quiet "$REVISION^{commit}")" \
  || die 1 "unknown revision: $REVISION"
BLOB="$(git rev-parse --verify --quiet "$SHA:$SPEC")" \
  || die 1 "approved revision $SHA does not contain $SPEC"

CURRENT="$(git hash-object "$SPEC")"
if [ "$CURRENT" != "$BLOB" ]; then
  die 1 "stale approval: $SPEC changed since approved revision $SHA; approved requirements are never silently replaced -- request re-approval"
fi

APPROVAL="$FEATURE_DIR/approval.json"
[ -f "$APPROVAL" ] \
  || die 1 "missing approval record: $APPROVAL (see docs/SPEC_START.md)"
approved_rev="$(sed -n 's/.*"revision"[: ]*"\([0-9a-fA-F]*\)".*/\1/p' "$APPROVAL" | sed -n 1p)"
approved_by="$(sed -n 's/.*"approved_by"[: ]*"\([^"]*\)".*/\1/p' "$APPROVAL" | sed -n 1p)"
[ -n "$approved_by" ] \
  || die 1 "approval record $APPROVAL has no approved_by; a human must approve the spec"
case "$SHA" in
  "$approved_rev") ;;
  *) die 1 "approval revision mismatch: record says '${approved_rev:-<empty>}', requested $SHA; approval is immutable" ;;
esac
log "approved spec ok: $SPEC @ $SHA (approved by $approved_by)"

missing=""
[ -f "$FEATURE_DIR/plan.md" ] || missing="plan.md"
[ -f "$FEATURE_DIR/tasks.md" ] || missing="${missing:+$missing, }tasks.md"
[ -z "$missing" ] || die 1 "missing planning artifacts: $missing in $FEATURE_DIR"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spec-converge.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

EVIDENCE_REL="$FEATURE_DIR/convergence/evidence"

# --- requirement tokens from the (gate-verified) approved spec ---------------
grep -oE '(FR|SC)-[0-9]+|REQ[0-9]+' "$SPEC" | sort -u > "$WORK/reqs" || true
log "requirement tokens: $(tr '\n' ' ' < "$WORK/reqs")"

# --- parse tasks: ids + states (same line format as spec-start.sh) -----------
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
    printf '%s\n' "$state" > "$WORK/$id.state"
  done < "$FEATURE_DIR/tasks.md"
}
parse_tasks
[ -n "$TASK_IDS" ] || die 1 "no tasks found in $FEATURE_DIR/tasks.md (expected lines like '- [ ] T001 ...')"

# --- parse findings (JSON Lines, sed-only field access; fields must not
# contain double quotes or backslashes -- controlled format) ------------------
GAP_COUNT=0
GAP_IDS=""
parse_findings() {
  n=0
  while IFS= read -r line; do
    case "$line" in
      ''|'{'*) ;;
      *) die 1 "malformed findings line (not a JSON object): $line" ;;
    esac
    n=$((n + 1))
    fid="$(printf '%s\n' "$line" | sed -n 's/.*"id": "\([^"]*\)".*/\1/p' | sed -n 1p)"
    freq="$(printf '%s\n' "$line" | sed -n 's/.*"requirement": "\([^"]*\)".*/\1/p' | sed -n 1p)"
    fkind="$(printf '%s\n' "$line" | sed -n 's/.*"kind": "\([^"]*\)".*/\1/p' | sed -n 1p)"
    fsum="$(printf '%s\n' "$line" | sed -n 's/.*"summary": "\([^"]*\)".*/\1/p' | sed -n 1p)"
    fev="$(printf '%s\n' "$line" | sed -n 's/.*"evidence": "\([^"]*\)".*/\1/p' | sed -n 1p)"
    case "$fkind" in
      missing|regression|verified) ;;
      *) die 1 "findings line $n has an invalid kind '${fkind:-<empty>}' (expected missing, regression, or verified)" ;;
    esac
    if [ "$fkind" = verified ]; then
      [ -n "$freq" ] || die 1 "verified findings line $n has no requirement"
      grep -Fxq "$freq" "$WORK/reqs" \
        || die 1 "verified findings line $n cites requirement $freq, which is not in the approved spec"
      # Issue #45: a verified record must identify the verification
      # method/result and point at evidence that actually exists.
      [ -n "$fsum" ] \
        || die 1 "verified findings line $n has no verification method/result"
      [ -n "$fev" ] \
        || die 1 "verified findings line $n has no evidence location"
      case "$fev" in
        /*|../*|*/../*|*/..)
          die 1 "verified findings line $n evidence must be a repository-relative path: $fev" ;;
      esac
      [ -e "$fev" ] \
        || die 1 "verified findings line $n cites evidence $fev, which does not exist in the repository"
      if ! grep -Fq "$freq	" "$WORK/verified.tsv" 2>/dev/null; then
        printf '%s\t%s\t%s\n' "$freq" "$fev" "$fsum" >> "$WORK/verified.tsv"
      fi
      continue
    fi
    [ -n "$fid" ] || die 1 "gap findings line $n has no id"
    case "$fid" in
      *[!A-Za-z0-9-]*) die 1 "gap id must be alphanumeric: $fid" ;;
    esac
    case " $GAP_IDS " in
      *" $fid "*) die 1 "duplicate gap id in findings: $fid" ;;
    esac
    [ -n "$fsum" ] || die 1 "gap $fid has no summary"
    GAP_IDS="$GAP_IDS $fid"
    GAP_COUNT=$((GAP_COUNT + 1))
    printf '%s\n' "$fid"   > "$WORK/gap.$GAP_COUNT.id"
    printf '%s\n' "$freq"  > "$WORK/gap.$GAP_COUNT.req"
    printf '%s\n' "$fkind" > "$WORK/gap.$GAP_COUNT.kind"
    printf '%s\n' "$fsum"  > "$WORK/gap.$GAP_COUNT.sum"
    printf '%s\n' "$fev"   > "$WORK/gap.$GAP_COUNT.ev"
  done < "$FINDINGS"
}
[ -z "$FINDINGS" ] || { [ -f "$FINDINGS" ] || die 1 "findings file not found: $FINDINGS"; parse_findings; }
[ -f "$WORK/verified.tsv" ] || : > "$WORK/verified.tsv"

in_approved_scope() { # in_approved_scope <requirement> (empty = whole spec)
  [ -z "$1" ] && return 0
  grep -Fxq "$1" "$WORK/reqs"
}

# --- dry-run: inputs validated, report the plan, never talk to gh ------------
if [ "$DRY_RUN" -eq 1 ]; then
  i=1
  while [ "$i" -le "$GAP_COUNT" ]; do
    id="$(cat "$WORK/gap.$i.id")"; req="$(cat "$WORK/gap.$i.req")"
    sum="$(cat "$WORK/gap.$i.sum")"
    if in_approved_scope "$req"; then
      [ "$JSON" -eq 0 ] && printf 'would create remediation: [%s/%s] %s (attempt 1)\n' "$FEATURE" "$id" "$sum"
    else
      [ "$JSON" -eq 0 ] && printf 'would report blocked: [%s/%s] requirement %s is outside the approved spec\n' "$FEATURE" "$id" "$req"
    fi
    i=$((i + 1))
  done
  if [ "$JSON" -eq 1 ]; then
    printf '{"feature":"%s","spec":"%s","revision":"%s","status":"dry-run","dry_run":true}\n' \
      "$FEATURE" "$SPEC" "$SHA"
  else
    printf 'summary: feature=%s status=dry-run gates=ok acceptance=not-run\n' "$FEATURE"
  fi
  exit 0
fi

# --- remote state via the plain gh CLI ----------------------------------------
command -v gh >/dev/null 2>&1 || die 1 "gh is required for convergence (not found in PATH)"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
  || die 1 "gh repo view failed; check authentication"

identity_prefix() { printf '[%s/%s]' "$FEATURE" "$1"; }
identity() { printf '%s/%s' "$FEATURE" "$1"; }

# Queue gate 1: no open issue in the feature milestone (blocked-labeled
# reports await humans and are exempt from the queue).
gh issue list --milestone "$FEATURE" --state open \
  --json number,title,labels --limit 1000 \
  --jq '.[] | select(([.labels[].name] | index("blocked")) == null) | [.number, .title] | @tsv' \
  > "$WORK/open.tsv" || die 1 "gh issue list failed; check authentication"
if [ -s "$WORK/open.tsv" ]; then
  while IFS="$(printf '\t')" read -r num title; do
    [ -n "$num" ] || continue
    log "open issue in milestone $FEATURE: #$num $title"
  done < "$WORK/open.tsv"
  die 3 "task queue not drained: open issues remain in milestone $FEATURE"
fi

gh issue list --state all --json number,title,state --limit 1000 \
  --jq '.[] | [.number, .title, .state] | @tsv' > "$WORK/existing.tsv" \
  || die 1 "gh issue list failed; check authentication"

# Queue gate 2: every unchecked task must already have an issue.
no_issue=""
for id in $TASK_IDS; do
  [ "$(cat "$WORK/$id.state")" = done ] && continue
  if ! awk -F'\t' -v p="$(identity_prefix "$id")" \
      'index($2, p) == 1 { found = 1; exit } END { exit !found }' "$WORK/existing.tsv"; then
    no_issue="$no_issue $(identity "$id")"
  fi
done
[ -z "$no_issue" ] \
  || die 3 "task queue not drained:$no_issue have no issue yet (run scripts/spec-start.sh first)"

if [ "$PRECHECK" -eq 1 ]; then
  log "queue drained: no open work in milestone $FEATURE"
  if [ "$JSON" -eq 1 ]; then
    printf '{"feature":"%s","spec":"%s","revision":"%s","status":"queue-drained","dry_run":false}\n' \
      "$FEATURE" "$SPEC" "$SHA"
  else
    printf 'queue: drained (milestone %s)\n' "$FEATURE"
  fi
  exit 0
fi

attempts_of() { # attempts_of <gap-id> -> issues ever created for the identity
  awk -F'\t' -v p="$(identity_prefix "$1")" \
    'index($2, p) == 1 { c++ } END { print c + 0 }' "$WORK/existing.tsv"
}

open_of() { # open_of <gap-id> -> issue number of an open issue with the identity
  awk -F'\t' -v p="$(identity_prefix "$1")" \
    'index($2, p) == 1 && $3 == "OPEN" { print $1; exit }' "$WORK/existing.tsv"
}

# --- integrated acceptance on the target branch -------------------------------
[ -f "$SELF_DIR/ci-gate.sh" ] \
  || die 1 "ci-gate.sh not found next to this script; configured acceptance cannot run"
bash "$SELF_DIR/ci-gate.sh" run --evidence-dir "$REPO_ROOT/$EVIDENCE_REL" \
  > "$WORK/acceptance.log" 2>&1
ACCEPTANCE_RC=$?
if [ "$ACCEPTANCE_RC" -eq 0 ]; then ACCEPTANCE=pass; else ACCEPTANCE=fail; fi
log "integrated acceptance: $ACCEPTANCE (exit $ACCEPTANCE_RC, evidence: $EVIDENCE_REL)"

# A failing acceptance run is itself a regression finding with evidence.
if [ "$ACCEPTANCE_RC" -ne 0 ]; then
  GAP_COUNT=$((GAP_COUNT + 1))
  printf 'integrated-acceptance\n' > "$WORK/gap.$GAP_COUNT.id"
  printf '\n'                    > "$WORK/gap.$GAP_COUNT.req"
  printf 'regression\n'          > "$WORK/gap.$GAP_COUNT.kind"
  printf 'Configured integration acceptance failed on the target branch\n' > "$WORK/gap.$GAP_COUNT.sum"
  printf '%s/gate.json\n' "$EVIDENCE_REL" > "$WORK/gap.$GAP_COUNT.ev"
  log "acceptance failure synthesized as regression gap integrated-acceptance"
fi

# Issue #45: a green integration run alone never establishes an approved
# requirement. Every requirement needs a verified evidence record; the ones
# an agent gap already cites come back with that gap, every other
# unevidenced requirement becomes its own remediation instead of being
# filled with generic acceptance evidence.
while IFS= read -r req; do
  [ -n "$req" ] || continue
  awk -F'\t' -v r="$req" '$1 == r { found = 1; exit } END { exit !found }' \
    "$WORK/verified.tsv" && continue
  covered=""
  j=1
  while [ "$j" -le "$GAP_COUNT" ]; do
    if [ "$(cat "$WORK/gap.$j.req")" = "$req" ]; then covered=1; break; fi
    j=$((j + 1))
  done
  [ -z "$covered" ] || continue
  GAP_COUNT=$((GAP_COUNT + 1))
  printf 'evidence-%s\n' "$req" > "$WORK/gap.$GAP_COUNT.id"
  printf '%s\n' "$req"         > "$WORK/gap.$GAP_COUNT.req"
  printf 'missing\n'           > "$WORK/gap.$GAP_COUNT.kind"
  printf 'No verified evidence for requirement %s; a green integration run alone does not establish it\n' "$req" \
    > "$WORK/gap.$GAP_COUNT.sum"
  printf '\n'                  > "$WORK/gap.$GAP_COUNT.ev"
  log "requirement $req has no verified evidence record; synthesized remediation gap evidence-$req"
done < "$WORK/reqs"

emit_json() { # emit_json <status> <created-list> <skipped-list> <blocked-list>
  printf '{"feature":"%s","spec":"%s","revision":"%s","status":"%s","acceptance":"%s","created":[%s],"skipped":[%s],"blocked":[%s],"dry_run":false}\n' \
    "$FEATURE" "$SPEC" "$SHA" "$1" "$ACCEPTANCE" "${2#,}" "${3#,}" "${4#,}"
}

# --- true completion: no gaps remain, acceptance passed, and every approved
# requirement carries a verified evidence record (issue #45) -------------------
if [ "$GAP_COUNT" -eq 0 ]; then
  TARGET="$(git rev-parse --verify HEAD^{commit})" \
    || die 1 "cannot resolve the validated code commit (HEAD)"
  COMPLETE_DIR="$FEATURE_DIR/convergence"
  mkdir -p "$COMPLETE_DIR" || die 1 "cannot create $COMPLETE_DIR"
  {
    printf '{\n'
    printf '  "feature": "%s",\n' "$FEATURE"
    printf '  "spec": "%s",\n' "$SPEC"
    printf '  "revision": "%s",\n' "$SHA"
    printf '  "status": "complete",\n'
    printf '  "acceptance": "pass",\n'
    printf '  "evidence": "%s/gate.json",\n' "$EVIDENCE_REL"
    printf '  "requirements": [\n'
    first=1
    while IFS= read -r req; do
      [ -n "$req" ] || continue
      ev="$(awk -F'\t' -v r="$req" '$1 == r { print $2; exit }' "$WORK/verified.tsv")"
      method="$(awk -F'\t' -v r="$req" '$1 == r { print $3; exit }' "$WORK/verified.tsv")"
      if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
      printf '    {"id": "%s", "status": "verified", "method": "%s", "evidence": "%s", "revision": "%s", "commit": "%s"}' \
        "$req" "$method" "$ev" "$SHA" "$TARGET"
    done < "$WORK/reqs"
    printf '\n  ]\n}\n'
  } > "$COMPLETE_DIR/complete.json"
  # Publish: closing the feature milestone is the remote-visible status.
  ms_num="$(gh api "repos/$repo/milestones" \
    --jq ".[] | select(.title == \"$FEATURE\") | .number" 2>/dev/null)"
  if [ -n "$ms_num" ]; then
    gh api -X PATCH "repos/$repo/milestones/$ms_num" -f state=closed >/dev/null 2>&1 \
      && log "milestone $FEATURE (#$ms_num) closed" \
      || log "warning: could not close milestone $FEATURE"
  else
    log "warning: milestone $FEATURE not found; completion recorded locally only"
  fi
  if [ "$JSON" -eq 1 ]; then
    emit_json complete "" "" ""
  else
    printf 'PROJECT-COMPLETE: feature=%s spec=%s@%s acceptance=pass record=%s\n' \
      "$FEATURE" "$SPEC" "$SHA" "$COMPLETE_DIR/complete.json"
    printf 'summary: feature=%s status=complete acceptance=pass created 0, skipped 0, blocked 0\n' "$FEATURE"
  fi
  exit 0
fi

# --- gaps remain: schedule deduplicated remediation within approved scope -----
created_list=""
skipped_list=""
blocked_list=""
created_count=0
skipped_count=0
blocked_count=0

ensure_milestone() {
  # Create the feature milestone if absent; a 422 (already exists) is fine.
  gh api "repos/$repo/milestones" -f title="$FEATURE" >/dev/null 2>&1 || true
}

i=1
while [ "$i" -le "$GAP_COUNT" ]; do
  id="$(cat "$WORK/gap.$i.id")"
  req="$(cat "$WORK/gap.$i.req")"
  kind="$(cat "$WORK/gap.$i.kind")"
  sum="$(cat "$WORK/gap.$i.sum")"
  ev="$(cat "$WORK/gap.$i.ev")"
  ident="$(identity "$id")"
  [ -n "$ev" ] || ev="(none recorded)"

  reason=""
  if ! in_approved_scope "$req"; then
    reason="requirement $req is outside the approved spec; extending scope requires re-approval"
  else
    attempts="$(attempts_of "$id")"
    if [ "$attempts" -ge "$BUDGET" ]; then
      reason="convergence budget exhausted after $attempts remediation attempt(s) (budget $BUDGET)"
    fi
  fi

  body_file="$WORK/gap.$i.body"
  {
    printf 'Autonomous convergence task generated from the approved spec (issue #21 workflow).\n\n'
    printf '## Finding\n'
    printf 'Kind: %s\n' "$kind"
    printf 'Requirement: %s\n' "${req:-<integrated acceptance>}"
    printf 'Summary: %s\n' "$sum"
    printf 'Evidence: %s\n' "$ev"
    printf '\n## Spec references\n'
    printf -- '- Spec: %s @ %s\n' "$SPEC" "$SHA"
    printf -- '- Plan: %s/plan.md\n' "$FEATURE_DIR"
    printf -- '- Tasks: %s/tasks.md\n' "$FEATURE_DIR"
    printf -- '- Finding identity: %s\n' "$ident"
    printf '\n## Status\n'
  } > "$body_file"

  open_num="$(open_of "$id")"
  if [ -n "$reason" ]; then
    blocked_list="$blocked_list,\"$ident\""
    blocked_count=$((blocked_count + 1))
    if [ -z "$open_num" ]; then
      ensure_milestone
      printf 'Blocked: %s.\nThis requirement stays unresolved; convergence will not publish completion until a human resolves it.\n' \
        "$reason" >> "$body_file"
      title="[$ident] $sum (blocked)"
      url="$(gh issue create --title "$title" --body-file "$body_file" \
        --label blocked --milestone "$FEATURE")" \
        || die 1 "gh issue create failed for blocked report $ident"
      if [ "$JSON" -eq 0 ]; then printf 'created #%s: %s\n' "${url##*/}" "$title"; fi
    else
      if [ "$JSON" -eq 0 ]; then printf 'skipped [%s] (blocked report #%s exists)\n' "$ident" "$open_num"; fi
    fi
    log "BLOCKED: [$ident] ($reason)"
  elif [ -n "$open_num" ]; then
    skipped_list="$skipped_list,\"$ident\""
    skipped_count=$((skipped_count + 1))
    if [ "$JSON" -eq 0 ]; then printf 'skipped [%s] (issue #%s already scheduled)\n' "$ident" "$open_num"; fi
  else
    ensure_milestone
    attempts="$(attempts_of "$id")"
    attempt=$((attempts + 1))
    {
      printf 'Attempt: %s of %s (convergence budget)\n' "$attempt" "$BUDGET"
      printf '\n## Scheduling\n'
      printf 'Queued via the `ready-for-agent` label; convergence re-runs after this work merges and the queue drains again.\n'
    } >> "$body_file"
    title="[$ident] $sum (attempt $attempt)"
    url="$(gh issue create --title "$title" --body-file "$body_file" \
      --label ready-for-agent --milestone "$FEATURE")" \
      || die 1 "gh issue create failed for remediation $ident"
    created_list="$created_list,\"$ident\""
    created_count=$((created_count + 1))
    if [ "$JSON" -eq 0 ]; then printf 'created #%s: %s\n' "${url##*/}" "$title"; fi
  fi
  i=$((i + 1))
done

if [ "$blocked_count" -gt 0 ]; then
  if [ "$JSON" -eq 1 ]; then
    emit_json blocked "$created_list" "$skipped_list" "$blocked_list"
  else
    printf 'summary: feature=%s status=blocked acceptance=%s created %s, skipped %s, blocked %s\n' \
      "$FEATURE" "$ACCEPTANCE" "$created_count" "$skipped_count" "$blocked_count"
  fi
  exit 4
fi

if [ "$JSON" -eq 1 ]; then
  emit_json remediation-scheduled "$created_list" "$skipped_list" "$blocked_list"
else
  printf 'summary: feature=%s status=remediation-scheduled acceptance=%s\n' \
    "$FEATURE" "$ACCEPTANCE"
fi
exit 0
