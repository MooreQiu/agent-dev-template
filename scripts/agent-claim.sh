#!/usr/bin/env bash
# Unified atomic claim protocol for automated workers (issue #18).
#
# Every dispatch path -- comment dispatch (claude.yml), assignment
# dispatch, the scheduled sweep and repair/reconcile runs -- claims a task
# through this script, so two workers can never execute the same issue.
#
# Registry: one git ref per task under refs/agent-claims/<key> on the
# shared origin. The ref content is a single-line JSON claim carrying the
# execution owner and an expiring lease:
#   {"key":"18","owner":"agent-sweep-123","acquired_at":1690000000,
#    "expires_at":1690010800,"status":"running","branch":"","pr":0}
# Atomicity comes from compare-and-swap pushes:
#   git push --force-with-lease=<ref>:<expect> origin <sha>:<ref>
# An empty <expect> means "the ref must not exist yet", so creation is a
# race-free test-and-set; updates and deletes hold the exact sha that was
# read. Losing a CAS race is how a worker learns someone else holds the
# task.
#
# Lease recovery: acquire may steal an expired claim; `reconcile` (run by
# the scheduled sweep before dispatch) releases claims whose leases ran
# out, cleans succeeded claims whose issues closed, and requeues succeeded
# claims whose PRs vanished -- applying the queue-repair labels.
#
# Usage:
#   agent-claim.sh acquire  <key> [--owner O] [--lease SECONDS]
#   agent-claim.sh release  <key> [--owner O] [--reason R] [--force]
#   agent-claim.sh renew    <key> --owner O [--lease SECONDS]
#   agent-claim.sh update   <key> --owner O --field k=v [--field k=v ...]
#   agent-claim.sh status   <key>
#   agent-claim.sh reconcile
#
# Exit codes: 0 = ok, 1 = error, 2 = usage, 3 = denied (claim held or
# not the owner).
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUDGET="$SELF_DIR/agent-budget.sh"

REMOTE="${AGENT_CLAIM_REMOTE:-origin}"
DEFAULT_LEASE="${AGENT_LEASE_SECONDS:-10800}"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/agent-claim.sh <command> <key> [options]
  acquire <key> [--owner O] [--lease SECONDS]
  release <key> [--owner O] [--reason R] [--force]
  renew   <key> --owner O [--lease SECONDS]
  update  <key> --owner O --field k=v [--field k=v ...]
  status  <key>
  reconcile
EOF
  exit 2
}

die() { printf 'claim: ERROR %s\n' "$*" >&2; exit 1; }

now_epoch() { date +%s; }

sanitize() { # strip characters that would break the single-line JSON
  printf '%s' "$1" | tr -d '"\\' | tr -d '\001-\037'
}

# --- minimal JSON access for the controlled single-line claim format -------

jstr() { # jstr <json> <key>
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}
jnum() { # jnum <json> <key> (empty when absent)
  printf '%s' "$1" | sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" | sed -n 1p
}

# --- registry primitives ----------------------------------------------------

claim_ref() { printf 'refs/agent-claims/%s' "$1"; }

read_claim() { # read_claim <key> -> prints JSON, rc 1 when absent
  ref="$(claim_ref "$1")"
  git fetch --quiet "$REMOTE" "$ref" 2>/dev/null || return 1
  git rev-parse --verify --quiet FETCH_HEAD >/dev/null 2>&1 || return 1
  git cat-file commit FETCH_HEAD 2>/dev/null | sed '1,/^$/d'
}

remote_claim_sha() { # remote_claim_sha <key> -> exact sha from origin
  git ls-remote "$REMOTE" "$(claim_ref "$1")" | sed -n "s/^\([0-9a-f]*\).*/\1/p"
}

write_claim() { # write_claim <key> <json> <expect-sha-or-empty> -> rc of CAS push
  ref="$(claim_ref "$1")"
  sha="$(printf '%s\n' "$2" | \
    env GIT_AUTHOR_NAME=agent-claim GIT_AUTHOR_EMAIL=agent-claim@invalid \
        GIT_COMMITTER_NAME=agent-claim GIT_COMMITTER_EMAIL=agent-claim@invalid \
    git commit-tree "$(git hash-object -t tree /dev/null)")"
  git push --quiet --force-with-lease="$ref:$3" "$REMOTE" "$sha:$ref" 2>/dev/null
}

delete_claim() { # delete_claim <key> <expect-sha> -> rc of CAS delete
  ref="$(claim_ref "$1")"
  git push --quiet --force-with-lease="$ref:$2" "$REMOTE" ":$ref" 2>/dev/null
}

is_expired() { # is_expired <json> <now>
  exp="$(jnum "$1" expires_at)"
  [ -n "$exp" ] && [ "$exp" -le "$2" ]
}

is_numeric_key() { printf '%s' "$1" | grep -Eq '^[0-9]+$'; }

# --- commands ----------------------------------------------------------------

cmd_acquire() {
  [ $# -ge 1 ] || usage
  key="$1"; shift
  owner=""
  lease="$DEFAULT_LEASE"
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) [ $# -ge 2 ] || usage; owner="$(sanitize "$2")"; shift 2 ;;
      --lease) [ $# -ge 2 ] || usage; lease="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$owner" ] || owner="worker-$(hostname 2>/dev/null || echo local)-$$"
  now="$(now_epoch)"

  current="$(read_claim "$key" || true)"
  if [ -n "$current" ]; then
    if ! is_expired "$current" "$now"; then
      holder="$(jstr "$current" owner)"
      exp="$(jnum "$current" expires_at)"
      printf 'claim: %s is held by %s (lease live until %s)\n' "$key" "$holder" "$exp"
      return 3
    fi
    expect="$(remote_claim_sha "$key")"
    printf 'claim: stealing expired claim for %s (previous owner %s)\n' \
      "$key" "$(jstr "$current" owner)"
  else
    expect=""
  fi

  json="$(printf '{"key":"%s","owner":"%s","acquired_at":%s,"expires_at":%s,"status":"running","branch":"","pr":0,"note":""}' \
    "$(sanitize "$key")" "$owner" "$now" "$((now + lease))")"
  if ! write_claim "$key" "$json" "$expect"; then
    printf 'claim: lost the race for %s (another worker holds it)\n' "$key"
    return 3
  fi
  printf 'claim: acquired %s owner=%s lease=%ss\n' "$key" "$owner" "$lease"
}

cmd_release() {
  [ $# -ge 1 ] || usage
  key="$1"; shift
  owner=""
  reason=""
  force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) [ $# -ge 2 ] || usage; owner="$(sanitize "$2")"; shift 2 ;;
      --reason) [ $# -ge 2 ] || usage; reason="$(sanitize "$2")"; shift 2 ;;
      --force) force=1; shift ;;
      *) usage ;;
    esac
  done

  expect="$(remote_claim_sha "$key")"
  [ -n "$expect" ] || { printf 'claim: %s is not claimed\n' "$key"; return 0; }
  if [ "$force" -ne 1 ]; then
    [ -n "$owner" ] || die "release requires --owner (or --force)"
    current="$(read_claim "$key" || true)"
    holder="$(jstr "$current" owner)"
    if [ "$holder" != "$owner" ] && ! is_expired "$current" "$(now_epoch)"; then
      printf 'claim: %s is owned by %s, refusing release by %s\n' "$key" "$holder" "$owner"
      return 3
    fi
  fi
  if ! delete_claim "$key" "$expect"; then
    printf 'claim: %s changed before release; retry\n' "$key"
    return 3
  fi
  printf 'claim: released %s%s\n' "$key" "${reason:+ (reason: $reason)}"
}

cmd_renew() {
  [ $# -ge 1 ] || usage
  key="$1"; shift
  owner=""
  lease="$DEFAULT_LEASE"
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) [ $# -ge 2 ] || usage; owner="$(sanitize "$2")"; shift 2 ;;
      --lease) [ $# -ge 2 ] || usage; lease="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$owner" ] || die "renew requires --owner"

  expect="$(remote_claim_sha "$key")"
  [ -n "$expect" ] || die "$key is not claimed"
  current="$(read_claim "$key" || true)"
  [ "$(jstr "$current" owner)" = "$owner" ] || {
    printf 'claim: %s is owned by %s, refusing renew by %s\n' "$key" "$(jstr "$current" owner)" "$owner"
    return 3
  }
  now="$(now_epoch)"
  json="$(printf '{"key":"%s","owner":"%s","acquired_at":%s,"expires_at":%s,"status":"%s","branch":"%s","pr":%s,"note":"%s"}' \
    "$(jstr "$current" key)" "$owner" "$(jnum "$current" acquired_at)" \
    "$((now + lease))" "$(jstr "$current" status)" "$(jstr "$current" branch)" \
    "$(jnum "$current" pr)" "$(jstr "$current" note)")"
  write_claim "$key" "$json" "$expect" || die "CAS push failed; claim changed under us"
  printf 'claim: renewed %s owner=%s lease=%ss\n' "$key" "$owner" "$lease"
}

cmd_update() {
  [ $# -ge 1 ] || usage
  key="$1"; shift
  owner=""
  fields=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) [ $# -ge 2 ] || usage; owner="$(sanitize "$2")"; shift 2 ;;
      --field)
        [ $# -ge 2 ] || usage
        case "$2" in
          status=*|branch=*|pr=*|note=*) fields="$fields $2" ;;
          *) die "unsupported --field $2 (allowed: status, branch, pr, note)" ;;
        esac
        shift 2
        ;;
      *) usage ;;
    esac
  done
  [ -n "$owner" ] || die "update requires --owner"

  expect="$(remote_claim_sha "$key")"
  [ -n "$expect" ] || die "$key is not claimed"
  current="$(read_claim "$key" || true)"
  [ "$(jstr "$current" owner)" = "$owner" ] || {
    printf 'claim: %s is owned by %s, refusing update by %s\n' "$key" "$(jstr "$current" owner)" "$owner"
    return 3
  }

  f_status="$(jstr "$current" status)"
  f_branch="$(jstr "$current" branch)"
  f_pr="$(jnum "$current" pr)"
  [ -n "$f_pr" ] || f_pr=0
  f_note="$(jstr "$current" note)"
  for f in $fields; do
    case "$f" in
      status=*) f_status="$(sanitize "${f#status=}")" ;;
      branch=*) f_branch="$(sanitize "${f#branch=}")" ;;
      pr=*) f_pr="${f#pr=}" ;;
      note=*) f_note="$(sanitize "${f#note=}")" ;;
    esac
  done
  f_pr="$(printf '%s' "$f_pr" | grep -Eo '[0-9]+' | sed -n 1p)"
  [ -n "$f_pr" ] || f_pr=0

  json="$(printf '{"key":"%s","owner":"%s","acquired_at":%s,"expires_at":%s,"status":"%s","branch":"%s","pr":%s,"note":"%s"}' \
    "$(jstr "$current" key)" "$owner" "$(jnum "$current" acquired_at)" \
    "$(jnum "$current" expires_at)" "$f_status" "$f_branch" "$f_pr" "$f_note")"
  write_claim "$key" "$json" "$expect" || die "CAS push failed; claim changed under us"
  printf 'claim: updated %s%s\n' "$key" "$(printf '%s' "$fields" | tr ' ' ',')"
}

cmd_status() {
  [ $# -eq 1 ] || usage
  current="$(read_claim "$1" || true)"
  if [ -z "$current" ]; then
    printf 'claim: %s is not claimed\n' "$1"
    return 1
  fi
  printf '%s\n' "$current"
}

# --- reconcile ----------------------------------------------------------------

# Repair-round budgeting (issue #22): every reconcile-driven requeue
# (expired lease, vanished PR) increments the durable repair counter;
# once it reaches max_repair_rounds the task is blocked for human review
# instead of being requeued into another autonomous failure loop.
repair_budget_exhausted() { # repair_budget_exhausted <key> -> rc 0 when blocked
  [ -x "$BUDGET" ] || return 1
  bash "$BUDGET" record "$1" --field repair_rounds=+1 >/dev/null 2>&1 || return 1
  rounds="$(bash "$BUDGET" show "$1" 2>/dev/null | sed -n 's/.*"repair_rounds":\([0-9][0-9]*\).*/\1/p')"
  max="$(bash "$BUDGET" limit max_repair_rounds 2>/dev/null)" || max=""
  [ -n "$rounds" ] && [ -n "$max" ] && [ "$rounds" -ge "$max" ]
}

announce_repair_blocked() { # announce_repair_blocked <key>
  gh issue edit "$1" --remove-label agent-claimed >/dev/null 2>&1 || true
  gh issue edit "$1" --add-label blocked >/dev/null 2>&1 || true
  if [ -x "$BUDGET" ]; then
    gh issue comment "$1" --body "$(bash "$BUDGET" summary "$1" 2>/dev/null)" \
      >/dev/null 2>&1 || true
  fi
}

issue_state() { # issue_state <key> -> OPEN/CLOSED/unknown
  gh issue view "$1" --json state 2>/dev/null | sed -n 's/.*"state":"\([^"]*\)".*/\1/p'
}

pr_open_for_branch() { # pr_open_for_branch <branch> -> rc 0 when a PR exists
  gh pr view "$1" --json number >/dev/null 2>&1
}

cmd_reconcile() {
  now="$(now_epoch)"
  repaired=0
  while IFS="$(printf '\t')" read -r sha ref; do
    [ -n "${sha:-}" ] && [ -n "${ref:-}" ] || continue
    key="${ref#refs/agent-claims/}"
    [ -n "$key" ] || continue
    current="$(read_claim "$key" || true)"
    [ -n "$current" ] || continue

    if is_expired "$current" "$now"; then
      if delete_claim "$key" "$sha"; then
        repaired=$((repaired + 1))
        printf 'reconcile: released expired claim %s (owner %s)\n' "$key" "$(jstr "$current" owner)"
        if is_numeric_key "$key" && command -v gh >/dev/null 2>&1; then
          if repair_budget_exhausted "$key"; then
            announce_repair_blocked "$key"
            printf 'reconcile: repair budget exhausted for %s; blocked for human review\n' "$key"
          else
            gh issue edit "$key" --remove-label agent-claimed >/dev/null 2>&1 || true
            gh issue edit "$key" --add-label agent-failed >/dev/null 2>&1 || true
            gh issue comment "$key" --body "Lease for automated work expired before completion; claim released and task requeued (see Actions logs)." >/dev/null 2>&1 || true
          fi
        fi
      fi
      continue
    fi

    status="$(jstr "$current" status)"
    if [ "$status" = "succeeded" ] && is_numeric_key "$key" \
       && command -v gh >/dev/null 2>&1; then
      state="$(issue_state "$key")"
      [ -n "$state" ] || continue
      branch="$(jstr "$current" branch)"
      requeue=0
      if [ "$state" != "CLOSED" ] && { [ -z "$branch" ] || ! pr_open_for_branch "$branch"; }; then
        requeue=1
      fi
      if [ "$state" = "CLOSED" ] || [ "$requeue" -eq 1 ]; then
        if delete_claim "$key" "$sha"; then
          repaired=$((repaired + 1))
          gh issue edit "$key" --remove-label agent-claimed >/dev/null 2>&1 || true
          if [ "$requeue" -eq 1 ]; then
            if repair_budget_exhausted "$key"; then
              announce_repair_blocked "$key"
              printf 'reconcile: repair budget exhausted for %s (PR missing); blocked for human review\n' "$key"
            else
              gh issue edit "$key" --add-label agent-failed >/dev/null 2>&1 || true
              gh issue comment "$key" --body "Claimed work reported success but its pull request is gone; task requeued for another run." >/dev/null 2>&1 || true
              printf 'reconcile: requeued %s (PR missing, issue open)\n' "$key"
            fi
          else
            printf 'reconcile: cleaned succeeded claim %s (issue closed)\n' "$key"
          fi
        fi
      fi
    fi
  done < <(git ls-remote "$REMOTE" 'refs/agent-claims/*' 2>/dev/null)
  printf 'reconcile: done (%s repair(s))\n' "$repaired"
}

# --- entry --------------------------------------------------------------------

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  acquire) cmd_acquire "$@" ;;
  release) cmd_release "$@" ;;
  renew) cmd_renew "$@" ;;
  update) cmd_update "$@" ;;
  status) cmd_status "$@" ;;
  reconcile) cmd_reconcile "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
