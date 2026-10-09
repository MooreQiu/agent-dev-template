#!/usr/bin/env bash
# Unified worker pipeline for automated tasks (issue #18).
#
# Every dispatch path (comment dispatch, assignment dispatch, scheduled
# sweep, retry/repair) runs a task through this script so that the
# mechanics are identical everywhere:
#
#   1. claim the task atomically (scripts/agent-claim.sh: owner + lease)
#   2. prepare an isolated clean worktree for branch agent/issue-<key>
#      from a freshly fetched target branch -- replacing any stale or
#      dirty worktree left by an interrupted run, and resuming an
#      existing remote branch instead of redoing finished work
#   3. execute the harness command inside the worktree
#   4. verify real artifacts: branch pushed, pull request exists, issue
#      linked, configured validation tests green -- never trusting the
#      CLI exit status alone
#   5. persist a machine-readable outcome (claim registry entry +
#      .agent/runs/task-*.json) and update claim bookkeeping: succeeded
#      claims are kept until reconcile cleans them; failures release the
#      claim and requeue with agent-failed
#
# Usage:
#   agent-task.sh prepare <key> [--target REF] [--root DIR]
#   agent-task.sh verify  <key> [--target REF] [--branch B]
#   agent-task.sh run     <key> [options] -- <command...>
#     options: --target REF (default origin/main), --lease SECONDS,
#              --owner O (default AGENT_OWNER or a run-unique fallback)
#
# Exit codes (run): 0 verified success, 3 claim held elsewhere,
# 4 verification failed, 5 preparation failed, 130 cancelled.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAIM="$SELF_DIR/agent-claim.sh"
REMOTE="${AGENT_CLAIM_REMOTE:-origin}"
DEFAULT_TARGET="$REMOTE/main"
DEFAULT_LEASE="${AGENT_LEASE_SECONDS:-10800}"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/agent-task.sh <command> <key> [options]
  prepare <key> [--target REF] [--root DIR]
  verify  <key> [--target REF] [--branch B]
  run     <key> [--target REF] [--lease SECONDS] [--owner O] -- <command...>
EOF
  exit 2
}

die() { printf 'task: ERROR %s\n' "$*" >&2; exit 1; }

repo_root() { git rev-parse --show-toplevel 2>/dev/null; }

branch_for() { printf 'agent/issue-%s' "$1"; }

worktree_for() { # worktree_for <root> <key>
  printf '%s/issue-%s' "$1" "$2"
}

target_branch_name() { # origin/main -> main
  printf '%s' "$1" | sed 's|^refs/remotes/[^/]*/||; s|^refs/heads/||'
}

# --- outcome persistence ------------------------------------------------------

outcome_write() { # outcome_write <json> <log-file-or-empty>
  root="$(repo_root)" || root="$(pwd)"
  runs="$root/.agent/runs"
  mkdir -p "$runs" || return 0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  printf '%s\n' "$1" > "$runs/task-${KEY:-unknown}-$stamp.json"
  [ -z "${2:-}" ] || cp "$2" "$runs/task-${KEY:-unknown}-$stamp.log" 2>/dev/null || true
  printf 'task-outcome: %s\n' "$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$GITHUB_STEP_SUMMARY" ]; then
    printf '```\n%s\n```\n' "$1" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

# --- prepare -------------------------------------------------------------------

cmd_prepare() {
  [ $# -ge 1 ] || usage
  KEY="$1"; shift
  TARGET="$DEFAULT_TARGET"
  ROOT="$(repo_root)" || die "not inside a git repository"
  ROOT="$ROOT/.agent-work"
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || usage; TARGET="$2"; shift 2 ;;
      --root) [ $# -ge 2 ] || usage; ROOT="$2"; shift 2 ;;
      *) usage ;;
    esac
  done

  BRANCH="$(branch_for "$KEY")"
  WT="$(worktree_for "$ROOT" "$KEY")"

  # Freshly fetch the target branch (and task branches) from origin.
  git fetch --quiet --prune "$REMOTE" || die "cannot fetch $REMOTE"

  # Replace any stale worktree left by an interrupted run -- retries and
  # dirty checkouts must never inherit modified state.
  if git worktree list --porcelain | grep -Fxq "worktree $WT"; then
    git worktree remove --force "$WT" 2>/dev/null \
      || { rm -rf "$WT"; git worktree prune; }
  elif [ -e "$WT" ]; then
    rm -rf "$WT"
  fi

  if git show-ref --verify --quiet "refs/remotes/$REMOTE/$BRANCH"; then
    # Partial success from an earlier run: resume the pushed branch. A
    # local branch that already contains the remote tip keeps its extra
    # commits (crash before push); a stale or diverged local resets to
    # the published remote state.
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
      if ! git merge-base --is-ancestor "refs/remotes/$REMOTE/$BRANCH" "$BRANCH"; then
        git branch -f "$BRANCH" "refs/remotes/$REMOTE/$BRANCH" 2>/dev/null || true
      fi
    else
      git branch "$BRANCH" "refs/remotes/$REMOTE/$BRANCH" 2>/dev/null \
        || die "cannot create $BRANCH"
    fi
    git worktree add "$WT" "$BRANCH" >/dev/null 2>&1 \
      || die "cannot attach worktree to $BRANCH"
    printf 'task: resumed existing branch %s in %s\n' "$BRANCH" "$WT"
  elif git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add "$WT" "$BRANCH" >/dev/null 2>&1 \
      || die "cannot attach worktree to $BRANCH"
    printf 'task: resumed local branch %s in %s\n' "$BRANCH" "$WT"
  else
    git worktree add -b "$BRANCH" "$WT" "$TARGET" >/dev/null 2>&1 \
      || die "cannot create worktree for $BRANCH from $TARGET"
    printf 'task: prepared %s from freshly fetched %s in %s\n' "$BRANCH" "$TARGET" "$WT"
  fi
  printf 'worktree: %s\n' "$WT"
}

# --- verify --------------------------------------------------------------------

configured_test_cmd() { # configured_test_cmd <dir> -> command or empty
  f="$1/.agent/project.json"
  [ -f "$f" ] || return 0
  sed -n '/^  "commands": {/,/^  }/p' "$f" \
    | sed -n 's/^ *"test": "\(.*\)",\{0,1\}$/\1/p'
}

do_verify() { # do_verify <worktree> <target> <branch> <harness-exit>
  WT="$1"; VTARGET="$2"; VBRANCH="$3"; HARNESS_RC="$4"
  BASE_NAME="$(target_branch_name "$VTARGET")"

  VSTATUS="failed"
  VPUSH="ok"
  VPR=0

  # 1. Branch must exist on the shared remote.
  if ! git -C "$WT" push --quiet "$REMOTE" "HEAD:refs/heads/$VBRANCH" 2>/dev/null; then
    VPUSH="failed"
    VREASON="push of $VBRANCH was rejected (diverged from remote? rebase needed)"
  else
    # 2. A pull request must exist for the task branch -- create it when
    #    the harness did not (idempotent resume of partial success).
    PR_JSON="$(gh pr view "$VBRANCH" --json number,body,state,url 2>/dev/null || true)"
    if [ -z "$PR_JSON" ]; then
      TITLE="$VBRANCH"
      if printf '%s' "$KEY" | grep -Eq '^[0-9]+$'; then
        TITLE="$(gh issue view "$KEY" --json title 2>/dev/null | sed -n 's/.*"title": *"\([^"]*\)".*/\1/p')"
        [ -n "$TITLE" ] || TITLE="$VBRANCH"
      fi
      if gh pr create --base "$BASE_NAME" --head "$VBRANCH" --title "$TITLE" \
          --body "Automated task run for #$KEY (resumed by agent-task.sh).

Closes #$KEY" >/dev/null 2>&1; then
        PR_JSON="$(gh pr view "$VBRANCH" --json number,body,state,url 2>/dev/null || true)"
      fi
    fi
    if [ -z "$PR_JSON" ]; then
      VREASON="no pull request exists for $VBRANCH (harness exit $HARNESS_RC is not proof of an artifact)"
    else
      VPR="$(printf '%s' "$PR_JSON" | sed -n 's/.*"number":\([0-9][0-9]*\).*/\1/p' | sed -n 1p)"
      # 3. The PR must link the issue so merging closes the loop.
      if ! printf '%s' "$PR_JSON" | grep -Eq "(Closes|Fixes|Resolves) #$KEY"; then
        PR_BODY="$(gh pr view "$VBRANCH" --json body --jq .body 2>/dev/null || true)"
        gh pr edit "$VPR" --body "$PR_BODY

Closes #$KEY" >/dev/null 2>&1 || true
        PR_JSON="$(gh pr view "$VBRANCH" --json number,body,state,url 2>/dev/null || true)"
      fi
      if printf '%s' "$PR_JSON" | grep -Eq "(Closes|Fixes|Resolves) #$KEY"; then
        # 4. Validation artifacts: the configured test suite must be green
        #    in the task worktree.
        VTEST_LOG="$(mktemp "${TMPDIR:-/tmp}/adt-verify.XXXXXX")"
        VTEST_RC=0
        TEST_CMD="$(configured_test_cmd "$WT")"
        if [ -n "$TEST_CMD" ]; then
          ( cd "$WT" && bash -c "$TEST_CMD" ) > "$VTEST_LOG" 2>&1
          VTEST_RC=$?
        fi
        if [ "$VTEST_RC" -eq 0 ]; then
          VSTATUS="succeeded"
          VREASON="branch pushed, PR #$VPR linked, validation green"
        else
          VREASON="configured test command failed (exit $VTEST_RC): $TEST_CMD"
        fi
      else
        VREASON="PR #$VPR does not link issue #$KEY"
      fi
    fi
  fi

  AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  OUTCOME="$(printf '{"key":"%s","status":"%s","branch":"%s","pr":%s,"harness_exit":%s,"push":"%s","test_exit":%s,"at":"%s","owner":"%s","reason":"%s"}' \
    "$KEY" "$VSTATUS" "$VBRANCH" "${VPR:-0}" "${HARNESS_RC:-0}" "$VPUSH" "${VTEST_RC:-0}" "$AT" "$OWNER" "${VREASON:-}")"
  outcome_write "$OUTCOME" "${VTEST_LOG:-}"
  [ -z "${VTEST_LOG:-}" ] || rm -f "$VTEST_LOG" 2>/dev/null || true

  if [ "$VSTATUS" = "succeeded" ]; then
    printf 'task: verified success -- %s\n' "$VREASON"
    return 0
  fi
  printf 'task: verification FAILED -- %s\n' "${VREASON:-unknown}"
  return 4
}

cmd_verify() {
  [ $# -ge 1 ] || usage
  KEY="$1"; shift
  TARGET="$DEFAULT_TARGET"
  ROOT="$(repo_root)" || die "not inside a git repository"
  ROOT="$ROOT/.agent-work"
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || usage; TARGET="$2"; shift 2 ;;
      --branch) [ $# -ge 2 ] || usage; BRANCH_OVERRIDE="$2"; shift 2 ;;
      --root) [ $# -ge 2 ] || usage; ROOT="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  BRANCH="${BRANCH_OVERRIDE:-$(branch_for "$KEY")}"
  WT="$(worktree_for "$ROOT" "$KEY")"
  [ -d "$WT" ] || die "no prepared worktree at $WT; run prepare first"
  OWNER="${AGENT_OWNER:-verify}"
  do_verify "$WT" "$TARGET" "$BRANCH" 0
}

# --- run -------------------------------------------------------------------------

cmd_run() {
  [ $# -ge 1 ] || usage
  KEY="$1"; shift
  TARGET="$DEFAULT_TARGET"
  LEASE="$DEFAULT_LEASE"
  OWNER="${AGENT_OWNER:-}"
  CMD=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || usage; TARGET="$2"; shift 2 ;;
      --lease) [ $# -ge 2 ] || usage; LEASE="$2"; shift 2 ;;
      --owner) [ $# -ge 2 ] || usage; OWNER="$2"; shift 2 ;;
      --) shift; CMD=("$@"); break ;;
      *) usage ;;
    esac
  done
  [ "${#CMD[@]}" -gt 0 ] || die "no harness command given after --"
  [ -n "$OWNER" ] || OWNER="task-${GITHUB_WORKFLOW:-local}-run-${GITHUB_RUN_ID:-none}-$$"

  # 1. Atomic claim: the single gate shared by every dispatch path.
  if ! bash "$CLAIM" acquire "$KEY" --owner "$OWNER" --lease "$LEASE"; then
    printf 'task: %s is claimed elsewhere; nothing to do\n' "$KEY"
    exit 3
  fi
  if printf '%s' "$KEY" | grep -Eq '^[0-9]+$' && command -v gh >/dev/null 2>&1; then
    gh issue edit "$KEY" --add-label agent-claimed >/dev/null 2>&1 || true
  fi

  fail_requeue() { # fail_requeue <exit-code> <reason>
    bash "$CLAIM" release "$KEY" --owner "$OWNER" --reason "$2" >/dev/null 2>&1 || true
    if printf '%s' "$KEY" | grep -Eq '^[0-9]+$' && command -v gh >/dev/null 2>&1; then
      gh issue edit "$KEY" --remove-label agent-claimed >/dev/null 2>&1 || true
      gh issue edit "$KEY" --add-label agent-failed >/dev/null 2>&1 || true
      gh issue comment "$KEY" --body "Automated run failed ($2); claim released and task requeued. See Actions logs." >/dev/null 2>&1 || true
    fi
    exit "$1"
  }

  CHILD=""
  cancelled() {
    [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null
    [ -n "$CHILD" ] && wait "$CHILD" 2>/dev/null
    bash "$CLAIM" release "$KEY" --owner "$OWNER" --reason cancelled >/dev/null 2>&1 || true
    if printf '%s' "$KEY" | grep -Eq '^[0-9]+$' && command -v gh >/dev/null 2>&1; then
      gh issue edit "$KEY" --remove-label agent-claimed >/dev/null 2>&1 || true
      gh issue comment "$KEY" --body "Automated run was cancelled; claim released. Partial work stays on the task branch for an idempotent resume." >/dev/null 2>&1 || true
    fi
    printf 'task: cancelled\n'
    exit 130
  }
  trap cancelled TERM INT

  # 2. Isolated, freshly prepared worktree (retries included).
  if ! bash "$0" prepare "$KEY" --target "$TARGET"; then
    fail_requeue 5 "worktree preparation failed"
  fi
  ROOT="$(repo_root)" || die "not inside a git repository"
  WT="$(worktree_for "$ROOT/.agent-work" "$KEY")"
  BRANCH="$(branch_for "$KEY")"

  # 3. Execute the harness inside the worktree.
  printf 'task: executing harness in %s\n' "$WT"
  HARNESS_RC=0
  (
    cd "$WT" || exit 1
    exec "${CMD[@]}"
  ) &
  CHILD=$!
  wait "$CHILD"
  HARNESS_RC=$?
  CHILD=""
  printf 'task: harness exited %s\n' "$HARNESS_RC"

  # 4. Verify artifacts and persist the outcome.
  if do_verify "$WT" "$TARGET" "$BRANCH" "$HARNESS_RC"; then
    # 5. Keep the succeeded claim (reconcile cleans it once the issue
    #    closes); record the outcome in the shared registry. VPR is set
    #    by do_verify for this very run -- no guessing from old files.
    bash "$CLAIM" update "$KEY" --owner "$OWNER" \
      --field status=succeeded --field "branch=$BRANCH" \
      --field "pr=${VPR:-0}" \
      >/dev/null 2>&1 || true
    exit 0
  fi
  fail_requeue 4 "artifact verification failed"
}

# --- entry --------------------------------------------------------------------

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  prepare) cmd_prepare "$@" ;;
  verify) cmd_verify "$@" ;;
  run) cmd_run "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
