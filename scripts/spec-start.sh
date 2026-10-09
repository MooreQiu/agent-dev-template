#!/usr/bin/env bash
# Start autonomous planning and issue generation from a human-approved
# specification. See docs/SPEC_START.md for the approval record format and
# the planning decision policy.
#
# Usage:
#   scripts/spec-start.sh <spec-path> <approved-revision> [--dry-run] [--json]
#
# <spec-path>      spec file relative to the repository root, e.g.
#                  specs/016-demo/spec.md
# <approved-revision> immutable commit SHA the human approved
# --dry-run        validate the gates and print what would be created;
#                  never talks to gh
# --json           print a single machine-readable JSON summary on stdout
#                  (for the scheduler in #17) instead of the human summary
#
# Exit codes: 0 = ok, 1 = gate failure (approval/revision/tasks),
#             2 = usage error, 3 = unmet planning prerequisites.
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
Usage: scripts/spec-start.sh <spec-path> <approved-revision> [--dry-run] [--json]
Starts autonomous planning and issue generation from a human-approved spec.
The spec must carry an approval record (specs/<feature>/approval.json) whose
revision matches <approved-revision>; see docs/SPEC_START.md.
EOF
}

SPEC=""
REVISION=""
DRY_RUN=0
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --json)    JSON=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage; die 2 "unknown option: $1" ;;
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

# --- gate 1: spec path is a tracked worktree file inside the repository ------
# (*\ ** rejects any path containing a space; quoted spec paths are not supported)
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

# --- gate 2: immutable revision resolves and contains the spec ---------------
SHA="$(git rev-parse --verify --quiet "$REVISION^{commit}")" \
  || die 1 "unknown revision: $REVISION"
BLOB="$(git rev-parse --verify --quiet "$SHA:$SPEC")" \
  || die 1 "approved revision $SHA does not contain $SPEC"

# --- gate 3: the worktree spec is identical to the approved revision ---------
CURRENT="$(git hash-object "$SPEC")"
if [ "$CURRENT" != "$BLOB" ]; then
  die 1 "stale approval: $SPEC changed since approved revision $SHA; approved requirements are never silently replaced -- request re-approval"
fi

# --- gate 4: a human approval record covers exactly this revision ------------
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

# --- gate 5: planning prerequisites (plan.md + tasks.md exist) ---------------
missing=""
[ -f "$FEATURE_DIR/plan.md" ] || missing="plan.md"
[ -f "$FEATURE_DIR/tasks.md" ] || missing="${missing:+$missing, }tasks.md"
[ -z "$missing" ] || die 3 "unmet planning prerequisites: $missing missing in $FEATURE_DIR; generate them as the specify role (/speckit-plan, /speckit-tasks) per docs/SPEC_START.md"

# --- parse tasks (bash 3.2 safe, no subshell state loss) ---------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spec-start.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TASK_IDS=""    # ordered ids from tasks.md
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
    desc="${rest#* }"
    [ "$desc" != "$rest" ] || desc=""
    case " $TASK_IDS " in
      *" $id "*) die 1 "duplicate task id in $FEATURE_DIR/tasks.md: $id" ;;
    esac
    TASK_IDS="$TASK_IDS $id"
    printf '%s\n' "$desc" > "$WORK/$id.desc"
    printf '%s\n' "$state" > "$WORK/$id.state"
    deps="$(printf '%s\n' "$desc" | sed -n 's/.*depends on \([^)]*\)).*/\1/p' | tr ',' ' ')"
    dep_ids=""
    for d in $deps; do
      case "$d" in
        T[0-9]*[0-9]) dep_ids="$dep_ids $d" ;;
      esac
    done
    printf '%s\n' "$dep_ids" > "$WORK/$id.deps"
  done < "$FEATURE_DIR/tasks.md"
}
parse_tasks
[ -n "$TASK_IDS" ] || die 1 "no tasks found in $FEATURE_DIR/tasks.md (expected lines like '- [ ] T001 ...')"
log "parsed tasks:$TASK_IDS"

identity() { printf '%s/%s' "$FEATURE" "$1"; }

# --- remote state via the plain gh CLI (the only remote interface) -----------
existing_number() { # existing_number <identity> -> issue number or empty
  [ -s "$WORK/existing.tsv" ] || return 0
  awk -F'\t' -v id="[$1]" 'index($2, id) == 1 { print $1; exit }' "$WORK/existing.tsv"
}

if [ "$DRY_RUN" -eq 0 ]; then
  command -v gh >/dev/null 2>&1 || die 1 "gh is required for issue generation (not found in PATH)"
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
    || die 1 "gh repo view failed; check authentication"
  gh issue list --state all --json number,title --limit 1000 \
    --jq '.[] | [.number, .title] | @tsv' > "$WORK/existing.tsv" \
    || die 1 "gh issue list failed; check authentication"
  # Create the feature milestone if absent; a 422 (already exists) is fine.
  gh api "repos/$repo/milestones" -f title="$FEATURE" >/dev/null 2>&1 || true
fi

# --- convert tasks to issues (feature-qualified identity) --------------------
created_count=0
skipped_count=0
blocked_count=0
created_nums=""
skipped_list=""
blocked_list=""
would_create=""

for id in $TASK_IDS; do
  state="$(cat "$WORK/$id.state")"
  desc="$(cat "$WORK/$id.desc")"
  ident="$(identity "$id")"

  if [ -z "$desc" ]; then
    die 1 "task $id in $FEATURE_DIR/tasks.md has no description"
  fi

  if [ "$state" = "done" ]; then
    skipped_count=$((skipped_count + 1))
    skipped_list="$skipped_list,\"$ident\""
    if [ "$JSON" -eq 0 ]; then printf 'skipped [%s] (checked in tasks.md)\n' "$ident"; fi
    continue
  fi

  num=""
  if [ "$DRY_RUN" -eq 0 ]; then
    num="$(existing_number "$ident")"
  fi
  if [ -n "$num" ]; then
    skipped_count=$((skipped_count + 1))
    skipped_list="$skipped_list,\"$ident\""
    if [ "$JSON" -eq 0 ]; then printf 'skipped [%s] (issue #%s exists)\n' "$ident" "$num"; fi
    echo "$num" > "$WORK/$id.num"
    continue
  fi

  # resolve intra-feature dependencies: created this run, existing issue,
  # completed in tasks.md, or pending later in the file; anything else is
  # genuinely unresolved and blocks the task instead of asking in CI.
  dep_refs=""
  unresolved=""
  for d in $(cat "$WORK/$id.deps"); do
    ref=""
    if [ -f "$WORK/$d.num" ]; then
      ref="#$(cat "$WORK/$d.num")"
    elif [ "$DRY_RUN" -eq 0 ]; then
      dn="$(existing_number "$(identity "$d")")"
      if [ -n "$dn" ]; then ref="#$dn"; fi
    fi
    if [ -z "$ref" ] && [ -f "$WORK/$d.state" ]; then
      dstate="$(cat "$WORK/$d.state")"
      if [ "$dstate" = "done" ]; then
        ref="completed:$(identity "$d")"
      else
        ref="$(identity "$d") (pending)"
      fi
    fi
    if [ -n "$ref" ]; then
      dep_refs="$dep_refs $ref"
    else
      unresolved="$unresolved $(identity "$d")"
    fi
  done

  if [ -n "$unresolved" ]; then
    labels="blocked"
  else
    labels="ready-for-agent"
  fi
  title_desc="${desc%% (depends on*}"
  title="[$ident] $title_desc"

  if [ "$DRY_RUN" -eq 1 ]; then
    would_create="$would_create,\"$ident\""
    if [ "$JSON" -eq 0 ]; then
      printf 'would create: %s (labels: %s)\n' "$title" "$labels"
    fi
    if [ -n "$unresolved" ]; then
      blocked_count=$((blocked_count + 1))
      blocked_list="$blocked_list,\"$ident\""
      [ "$JSON" -eq 0 ] && printf 'blocked [%s] (unresolved deps:%s)\n' "$ident" "$unresolved"
    fi
    continue
  fi

  body_file="$WORK/$id.body"
  {
    printf 'Autonomous task generated from a human-approved specification.\n\n'
    printf '## Acceptance criteria\n'
    printf -- '- [ ] %s\n\n' "$desc"
    printf '## Spec references\n'
    printf -- '- Spec: %s @ %s\n' "$SPEC" "$SHA"
    printf -- '- Plan: %s/plan.md\n' "$FEATURE_DIR"
    printf -- '- Tasks: %s/tasks.md\n' "$FEATURE_DIR"
    printf -- '- Task identity: %s\n\n' "$ident"
    printf '## Dependencies\n'
    if [ -n "$dep_refs" ]; then
      printf 'Depends:%s\n' "$dep_refs"
    else
      printf 'Depends: None\n'
    fi
    if [ -n "$unresolved" ]; then
      printf 'Unresolved:%s -- blocked until these dependencies exist in tasks.md.\n' "$unresolved"
    fi
    printf '\n## Scheduling\n'
    if [ "$labels" = "blocked" ]; then
      printf 'Blocked: not queued until the unresolved dependencies above are resolved.\n'
    else
      printf 'Eligible for agent scheduling via the `ready-for-agent` queue label; start order is gated by the dependencies above.\n'
    fi
  } > "$body_file"

  url="$(gh issue create --title "$title" --body-file "$body_file" \
    --label "$labels" --milestone "$FEATURE")" \
    || die 1 "gh issue create failed for $ident"
  num="${url##*/}"
  echo "$num" > "$WORK/$id.num"
  created_count=$((created_count + 1))
  created_nums="$created_nums,$num"
  if [ -n "$unresolved" ]; then
    blocked_count=$((blocked_count + 1))
    blocked_list="$blocked_list,\"$ident\""
  fi
  if [ "$JSON" -eq 0 ]; then
    printf 'created #%s: %s\n' "$num" "$title"
    if [ -n "$unresolved" ]; then
      printf 'blocked [%s] (unresolved deps:%s)\n' "$ident" "$unresolved"
    fi
  fi
done

# --- summary ------------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  printf '{"feature":"%s","spec":"%s","revision":"%s","created":[%s],"skipped":[%s],"blocked":[%s],"would_create":[%s],"dry_run":%s}\n' \
    "$FEATURE" "$SPEC" "$SHA" \
    "${created_nums#,}" "${skipped_list#,}" "${blocked_list#,}" "${would_create#,}" \
    "$DRY_RUN"
else
  printf 'summary: feature=%s spec=%s@%s created %s, skipped %s, blocked %s\n' \
    "$FEATURE" "$SPEC" "$SHA" "$created_count" "$skipped_count" "$blocked_count"
fi
