#!/usr/bin/env bash
# Dependency- and priority-aware scheduler for autonomous tasks (issue #17).
#
# Decides WHAT to work on next, on every dispatch path that advances the
# queue autonomously: the merge-triggered scheduler workflow, newly
# available work, and the periodic sweep (recovery). Selection rules:
#
#   1. Inspect the COMPLETE applicable queue: gh issue list with an
#      explicit large --limit, never the default API page.
#   2. Exclude closed work (query), issues with assignees, held claims
#      (agent-claimed label, maintained by scripts/agent-claim.sh),
#      blocked-label issues, and issues whose work is already merged or
#      whose pull request is open and waiting for review -- so merged and
#      in-flight work is never duplicated.
#   3. p0 blocking semantics: while ANY p0 issue sits open in the
#      ready-for-agent queue, only p0 work is schedulable -- even when
#      the p0 itself is dependency-blocked (the queue is held until a
#      human resolves it). Otherwise order p0 < p1 < p2 < p3 < unlabeled,
#      then oldest issue first.
#   4. Dependency metadata: "#N" refs inside the "## Dependencies"
#      section of the issue body (both "Depends: #N ..." and bare
#      "#N, #M" lists). A prerequisite counts as satisfied ONLY when a
#      MERGED pull request links it (Closes/Fixes/Resolves #N) -- an
#      issue merely closed or marked complete by an agent does not
#      unlock its dependents, and spec-task refs without "#" are treated
#      as already resolved by spec-start.sh contracts.
#
# Scheduling stays SERIAL (one task per event; agent-task.sh fetches the
# latest target branch before every task), preserving dependency order:
# a dependent can only become eligible after its prerequisite merged.
# Duplicate events converge on the same selection and are deduped by the
# unified claim protocol's atomic acquire.
#
# Usage:
#   agent-schedule.sh next                print the single best issue number
#   agent-schedule.sh list [--limit N]    print up to N numbers in order
#
# Decisions for skipped issues go to stderr; stdout carries only the
# selected issue numbers. Exit codes: 0 ok (empty output = queue has no
# eligible task), 1 error, 2 usage.
set -u

QUEUE_LIMIT="${AGENT_SCHEDULE_LIMIT:-1000}"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/agent-schedule.sh <command> [options]
  next                print the best eligible issue number
  list [--limit N]    print eligible issue numbers in schedule order
EOF
  exit 2
}

die() { printf 'schedule: ERROR %s\n' "$*" >&2; exit 1; }

note() { printf 'schedule: %s\n' "$*" >&2; }

TAB="$(printf '\t')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/adt-schedq.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

command -v gh >/dev/null 2>&1 || die "gh is required (not found in PATH)"

# --- remote state (one call each, cached for the whole selection) -------------

fetch_queue() {
  gh issue list --label ready-for-agent --state open --limit "$QUEUE_LIMIT" \
    --json number,title,body,labels,assignees \
    --jq '.[] | [.number, ([.labels[].name] | join(",")),
                 ((.assignees | length) | tostring), .body] | @tsv' \
    > "$WORK/queue.tsv" || die "cannot list the ready-for-agent queue"
}

fetch_prs() { # fetch_prs <state> <file>
  gh pr list --state "$1" --limit "$QUEUE_LIMIT" --json number,body \
    --jq '.[] | [.number, .body] | @tsv' > "$2" \
    || die "cannot list $1 pull requests"
}

# --- predicates ----------------------------------------------------------------

has_label() { # has_label <labels-csv> <label>
  case ",$1," in *",$2,"*) return 0 ;; esac
  return 1
}

pr_links() { # pr_links <pr-tsv> <issue-number> -- any PR whose body closes #N
  grep -Eq "(Closes|Fixes|Resolves) #$2([^0-9]|$)" "$1" 2>/dev/null
}

dep_refs() { # dep_refs <escaped-body> -> prints "#N" refs from ## Dependencies
  printf '%b' "$1" \
    | awk '/^## Dependencies[ \t]*$/{f=1; next} /^## /{f=0} f' \
    | grep -o '#[0-9][0-9]*' | sort -u | tr '\n' ' '
}

rank_of() { # rank_of <labels-csv> -> 0..3 for p0..p3, 4 unlabeled
  r=0
  while [ "$r" -le 3 ]; do
    if has_label "$1" "p$r"; then printf '%s' "$r"; return 0; fi
    r=$((r + 1))
  done
  printf '4'
}

# --- selection -----------------------------------------------------------------

select_batch() { # select_batch [max] -> numbers on stdout, reasons on stderr
  fetch_queue
  fetch_prs merged "$WORK/merged.tsv"
  fetch_prs open "$WORK/open.tsv"

  # p0 gate over the raw open queue: an outstanding p0 holds all other
  # work, claimed or not (documented "p0 blocks everything" semantics).
  has_p0=0
  while IFS="$TAB" read -r n labels nassignees body; do
    [ -n "${n:-}" ] || continue
    if has_label "$labels" p0; then
      has_p0=1
      break
    fi
  done < "$WORK/queue.tsv"

  : > "$WORK/eligible.tsv"
  while IFS="$TAB" read -r n labels nassignees body; do
    [ -n "${n:-}" ] || continue
    if [ "$nassignees" != "0" ]; then
      note "#$n skipped: has assignees"
      continue
    fi
    if has_label "$labels" agent-claimed; then
      note "#$n skipped: claim held (agent-claimed)"
      continue
    fi
    if has_label "$labels" blocked; then
      note "#$n skipped: blocked label"
      continue
    fi
    if [ "$has_p0" -eq 1 ] && ! has_label "$labels" p0; then
      note "#$n held: a p0 issue blocks all other work"
      continue
    fi
    if pr_links "$WORK/merged.tsv" "$n"; then
      note "#$n skipped: work already merged"
      continue
    fi
    if pr_links "$WORK/open.tsv" "$n"; then
      note "#$n skipped: pull request open and in review"
      continue
    fi
    unsat=""
    for d in $(dep_refs "$body"); do
      if ! pr_links "$WORK/merged.tsv" "${d#\#}"; then
        unsat="$unsat $d"
      fi
    done
    if [ -n "$unsat" ]; then
      note "#$n skipped: dependencies not merged:$unsat"
      continue
    fi
    printf '%s|%s\n' "$(rank_of "$labels")" "$n" >> "$WORK/eligible.tsv"
  done < "$WORK/queue.tsv"

  [ -s "$WORK/eligible.tsv" ] || return 0
  ordered="$(sort -t'|' -k1,1n -k2,2n "$WORK/eligible.tsv" | cut -d'|' -f2)"
  max="${1:-0}"
  case "$max" in
    ''|0) printf '%s\n' "$ordered" ;;
    *) printf '%s\n' "$ordered" | sed -n "1,${max}p" ;;
  esac
}

# --- entry -----------------------------------------------------------------------

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  next)
    [ $# -eq 0 ] || usage
    n="$(select_batch 1)"
    if [ -z "$n" ]; then
      note "queue has no eligible task right now"
      exit 0
    fi
    printf '%s\n' "$n"
    ;;
  list)
    limit=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --limit) [ $# -ge 2 ] || usage; limit="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    if [ "$limit" != "0" ] && ! printf '%s' "$limit" | grep -Eq '^[1-9][0-9]*$'; then
      usage
    fi
    select_batch "$limit"
    ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
