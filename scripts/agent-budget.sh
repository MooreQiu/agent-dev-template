#!/usr/bin/env bash
# Run budgets and durable progress state for autonomous workers (issue #22).
#
# Every automated run is bounded by project-wide limits declared in
# .agent/budgets.json and enforced by scripts/agent-task.sh between
# pipeline stages:
#
#   max_attempts_per_issue        retry budget: harness runs started per task
#   max_repair_rounds             reconcile-driven requeues per task
#   max_convergence_rounds        project policy for spec-converge remediation
#   max_elapsed_seconds_per_run   wall-clock budget for a single run
#   max_steps_per_run             pipeline stages executed in a single run
#
# Model/API usage: the pipeline cannot observe token consumption of the
# harness, so invocation counts (attempts + repair rounds) are the
# measurable proxy -- see docs/BUDGETS.md for the cost-estimate
# limitations. An invalid budgets file fails closed: consumers die
# instead of running unbounded.
#
# Durable status: one git ref per task under refs/agent-status/<key> on
# the shared origin (same CAS technique as refs/agent-claims/<key>),
# surviving crashes and visible to humans without any external system:
#   {"key":"22","task":"issue #22","branch":"","pr":0,"spec_revision":"",
#    "phase":"executing","attempts":2,"repair_rounds":1,
#    "started_at":1690000000,"updated_at":1690000100,
#    "last_failure":"artifact verification failed","control":""}
#
# Human controls (repository-native, via issue labels):
#   agent-paused    workers refuse to start; an in-flight run stops at
#                   the next stage gate keeping resumable state; remove
#                   the label to resume
#   agent-cancelled workers refuse to start until a human clears it
#
# Usage:
#   agent-budget.sh limits                       print effective limits
#   agent-budget.sh limit <name>                 print one limit value
#   agent-budget.sh check <key>                  pre-run gate
#   agent-budget.sh record <key> --field k=v ... persist durable status
#   agent-budget.sh show <key>                   print durable status JSON
#   agent-budget.sh summary <key>                print a markdown summary
#
# Exit codes (check): 0 within budget, 6 budget exhausted,
# 7 stopped by a human control. Other commands: 0 ok, 1 error,
# 2 usage, 3 lost the CAS race.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${AGENT_CLAIM_REMOTE:-origin}"
LIMIT_KEYS="max_attempts_per_issue max_repair_rounds max_convergence_rounds max_elapsed_seconds_per_run max_steps_per_run"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/agent-budget.sh <command> [options]
  limits                       print effective limits (key=value lines)
  limit <name>                 print one limit value
  check <key>                  rc 0 ok / 6 exhausted / 7 control stop
  record <key> --field k=v ... update durable status (k=+1 increments)
  show <key>                   print durable status JSON
  summary <key>                print a human-readable markdown summary
EOF
  exit 2
}

die() { printf 'budget: ERROR %s\n' "$*" >&2; exit 1; }

now_epoch() { date +%s; }

sanitize() { # strip characters that would break the single-line JSON
  printf '%s' "$1" | tr -d '"\\' | tr -d '\001-\037'
}

repo_root() { git rev-parse --show-toplevel 2>/dev/null; }

# --- minimal JSON access for the controlled single-line formats -----------

jstr() { # jstr <json> <key>
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}
jnum() { # jnum <json> <key> (empty when absent)
  printf '%s' "$1" | sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" | sed -n 1p
}

# --- limits ---------------------------------------------------------------

budgets_file() {
  if [ -n "${AGENT_BUDGET_FILE:-}" ]; then
    printf '%s' "$AGENT_BUDGET_FILE"
  elif root="$(repo_root)" && [ -f "$root/.agent/budgets.json" ]; then
    printf '%s/.agent/budgets.json' "$root"
  else
    printf '%s/../.agent/budgets.json' "$SELF_DIR"
  fi
}

default_limit() { # default_limit <name>
  case "$1" in
    max_attempts_per_issue) printf '3' ;;
    max_repair_rounds) printf '3' ;;
    max_convergence_rounds) printf '2' ;;
    max_elapsed_seconds_per_run) printf '10800' ;;
    max_steps_per_run) printf '8' ;;
    *) die "unknown limit '$1' (allowed: $LIMIT_KEYS)" ;;
  esac
}

limit_value() { # limit_value <name> -> prints validated value
  name="$1"
  case "$name" in
    max_attempts_per_issue|max_repair_rounds|max_convergence_rounds \
    |max_elapsed_seconds_per_run|max_steps_per_run) ;;
    *) die "unknown limit '$name' (allowed: $LIMIT_KEYS)" ;;
  esac
  file="$(budgets_file)"
  val=""
  if [ -f "$file" ]; then
    val="$(sed -n "s/.*\"$name\": *\([0-9][0-9]*\).*/\1/p" "$file" | sed -n 1p)"
    if [ -n "$val" ]; then
      # A value like 2.5 or 1e3 must fail closed, not truncate to 2 or 1:
      # after the integer only JSON delimiters may follow on that line.
      rest="$(sed -n "s/.*\"$name\": *[0-9][0-9]*//p" "$file" | sed -n 1p | sed 's/^[[:space:]]*//')"
      case "$rest" in
        ''|,*|}*) ;;
        *) die "$file declares '$name' but it is not a positive integer (got '$val$rest'); refusing to run unbounded" ;;
      esac
    elif grep -Fq "\"$name\":" "$file"; then
      die "$file declares '$name' but it is not a positive integer (got '$(grep -Fo "\"$name\":" "$file" | sed -n 1p)...'); refusing to run unbounded"
    fi
  fi
  [ -n "$val" ] || val="$(default_limit "$name")"
  case "$val" in
    ''|*[!0-9]*|0) die "limit '$name' must be a positive integer (got '$val')" ;;
  esac
  printf '%s' "$val"
}

cmd_limits() {
  for name in $LIMIT_KEYS; do
    val="$(limit_value "$name")" || exit 1
    printf '%s=%s\n' "$name" "$val"
  done
}

cmd_limit() {
  [ $# -eq 1 ] || usage
  limit_value "$1"
}

# --- durable status registry (refs/agent-status/<key>) ---------------------

status_ref() { printf 'refs/agent-status/%s' "$1"; }

read_status() { # read_status <key> -> prints JSON, rc 1 when absent
  ref="$(status_ref "$1")"
  git fetch --quiet "$REMOTE" "$ref" 2>/dev/null || return 1
  git rev-parse --verify --quiet FETCH_HEAD >/dev/null 2>&1 || return 1
  git cat-file commit FETCH_HEAD 2>/dev/null | sed '1,/^$/d'
}

remote_status_sha() { # remote_status_sha <key> -> exact sha from origin
  git ls-remote "$REMOTE" "$(status_ref "$1")" | sed -n 's/^\([0-9a-f]*\).*/\1/p'
}

write_status() { # write_status <key> <json> <expect-sha-or-empty> -> rc of CAS push
  ref="$(status_ref "$1")"
  sha="$(printf '%s\n' "$2" | \
    env GIT_AUTHOR_NAME=agent-budget GIT_AUTHOR_EMAIL=agent-budget@invalid \
        GIT_COMMITTER_NAME=agent-budget GIT_COMMITTER_EMAIL=agent-budget@invalid \
    git commit-tree "$(git hash-object -t tree /dev/null)")"
  git push --quiet --force-with-lease="$ref:$3" "$REMOTE" "$sha:$ref" 2>/dev/null
}

task_label() { # task_label <key>
  if printf '%s' "$1" | grep -Eq '^[0-9]+$'; then
    printf 'issue #%s' "$1"
  else
    printf '%s' "$1"
  fi
}

cmd_record() {
  [ $# -ge 1 ] || usage
  key="$1"; shift
  fields=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --field)
        [ $# -ge 2 ] || usage
        case "$2" in
          phase=*|branch=*|last_failure=*|spec_revision=*|control=*|task=* \
          |attempts=*|repair_rounds=*|pr=*) fields+=("$2") ;;
          *) die "unsupported --field '$2' (allowed: task, branch, pr, spec_revision, phase, attempts, repair_rounds, last_failure, control)" ;;
        esac
        shift 2
        ;;
      *) usage ;;
    esac
  done
  [ "${#fields[@]}" -gt 0 ] || die "record requires at least one --field k=v"

  current="$(read_status "$key" || true)"
  f_task="$(jstr "${current:-}" task)"; [ -n "$f_task" ] || f_task="$(task_label "$key")"
  f_branch="$(jstr "${current:-}" branch)"
  f_pr="$(jnum "${current:-}" pr)"; [ -n "$f_pr" ] || f_pr=0
  f_spec="$(jstr "${current:-}" spec_revision)"
  f_phase="$(jstr "${current:-}" phase)"; [ -n "$f_phase" ] || f_phase="idle"
  f_attempts="$(jnum "${current:-}" attempts)"; [ -n "$f_attempts" ] || f_attempts=0
  f_repairs="$(jnum "${current:-}" repair_rounds)"; [ -n "$f_repairs" ] || f_repairs=0
  f_started="$(jnum "${current:-}" started_at)"
  [ "$f_started" = "0" ] && f_started="" # 0 means "never started"
  f_failure="$(jstr "${current:-}" last_failure)"
  f_control="$(jstr "${current:-}" control)"

  for f in "${fields[@]}"; do
    case "$f" in
      task=*) f_task="$(sanitize "${f#task=}")" ;;
      branch=*) f_branch="$(sanitize "${f#branch=}")" ;;
      spec_revision=*) f_spec="$(sanitize "${f#spec_revision=}")" ;;
      phase=*) f_phase="$(sanitize "${f#phase=}")" ;;
      last_failure=*) f_failure="$(sanitize "${f#last_failure=}")" ;;
      control=*) f_control="$(sanitize "${f#control=}")" ;;
      pr=*) f_pr="$(printf '%s' "${f#pr=}" | grep -Eo '[0-9]+' | sed -n 1p)"; [ -n "$f_pr" ] || f_pr=0 ;;
      attempts=*)
        v="${f#attempts=}"
        if [ "$v" = "+1" ]; then f_attempts=$((f_attempts + 1)); [ -n "$f_started" ] || f_started="$(now_epoch)"
        else f_attempts="$(printf '%s' "$v" | grep -Eo '[0-9]+' | sed -n 1p)"; [ -n "$f_attempts" ] || f_attempts=0; fi ;;
      repair_rounds=*)
        v="${f#repair_rounds=}"
        if [ "$v" = "+1" ]; then f_repairs=$((f_repairs + 1))
        else f_repairs="$(printf '%s' "$v" | grep -Eo '[0-9]+' | sed -n 1p)"; [ -n "$f_repairs" ] || f_repairs=0; fi ;;
    esac
  done

  json="$(printf '{"key":"%s","task":"%s","branch":"%s","pr":%s,"spec_revision":"%s","phase":"%s","attempts":%s,"repair_rounds":%s,"started_at":%s,"updated_at":%s,"last_failure":"%s","control":"%s"}' \
    "$(sanitize "$key")" "$f_task" "$f_branch" "$f_pr" "$f_spec" "$f_phase" \
    "$f_attempts" "$f_repairs" "${f_started:-0}" "$(now_epoch)" "$f_failure" "$f_control")"
  expect="$(remote_status_sha "$key")"
  if ! write_status "$key" "$json" "$expect"; then
    printf 'budget: lost the race updating status for %s; retry\n' "$key" >&2
    exit 3
  fi
  printf '%s\n' "$json"
}

cmd_show() {
  [ $# -eq 1 ] || usage
  current="$(read_status "$1" || true)"
  if [ -z "$current" ]; then
    printf 'budget: no durable status recorded for %s\n' "$1" >&2
    return 1
  fi
  printf '%s\n' "$current"
}

# --- human-facing summary ---------------------------------------------------

fmt_time() { # fmt_time <epoch-or-0>
  [ -n "$1" ] && [ "$1" -gt 0 ] 2>/dev/null || { printf 'never'; return; }
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$1"
}

cmd_summary() {
  [ $# -eq 1 ] || usage
  key="$1"
  current="$(read_status "$key" || true)"
  maxa="$(limit_value max_attempts_per_issue)" || exit 1
  maxr="$(limit_value max_repair_rounds)" || exit 1
  maxc="$(limit_value max_convergence_rounds)" || exit 1
  if [ -z "$current" ]; then
    printf '## Agent status: %s\n\n- No durable status recorded yet (never dispatched under issue #22 budgets).\n- Budgets: attempts 0/%s, repair rounds 0/%s, convergence policy %s rounds\n' \
      "$(task_label "$key")" "$maxa" "$maxr" "$maxc"
    return 0
  fi
  task="$(jstr "$current" task)"; [ -n "$task" ] || task="$(task_label "$key")"
  branch="$(jstr "$current" branch)"
  pr="$(jnum "$current" pr)"
  spec="$(jstr "$current" spec_revision)"
  phase="$(jstr "$current" phase)"
  attempts="$(jnum "$current" attempts)"; [ -n "$attempts" ] || attempts=0
  repairs="$(jnum "$current" repair_rounds)"; [ -n "$repairs" ] || repairs=0
  failure="$(jstr "$current" last_failure)"
  control="$(jstr "$current" control)"
  printf '## Agent status: %s\n\n' "$task"
  printf -- '- Task: %s\n' "$task"
  printf -- '- Branch: %s\n' "${branch:-none}"
  if [ -n "$pr" ] && [ "$pr" -gt 0 ]; then
    printf -- '- PR: #%s\n' "$pr"
  else
    printf -- '- PR: none\n'
  fi
  printf -- '- Spec revision: %s\n' "${spec:-unknown (task not launched from an approved spec)}"
  printf -- '- Phase: %s\n' "${phase:-unknown}"
  printf -- '- Attempts: %s/%s (retry budget)\n' "$attempts" "$maxa"
  printf -- '- Repair rounds: %s/%s\n' "$repairs" "$maxr"
  printf -- '- Convergence policy: %s rounds\n' "$maxc"
  printf -- '- Last failure: %s\n' "${failure:-none}"
  [ -z "$control" ] || printf -- '- Control: %s\n' "$control"
  printf -- '- Updated (UTC): %s\n' "$(fmt_time "$(jnum "$current" updated_at)")"
}

# --- pre-run gate -----------------------------------------------------------

is_numeric_key() { printf '%s' "$1" | grep -Eq '^[0-9]+$'; }

issue_label_set() { # issue_label_set <key> -> prints label names, one per line
  gh issue view "$1" --json labels 2>/dev/null | tr ',' '\n' \
    | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p'
}

cmd_check() {
  [ $# -eq 1 ] || usage
  key="$1"

  if is_numeric_key "$key" && command -v gh >/dev/null 2>&1; then
    labels="$(issue_label_set "$key")"
    if printf '%s\n' "$labels" | grep -Fxq agent-cancelled; then
      printf 'budget: %s stopped by control: agent-cancelled (a human cancelled this task; clear the label to re-queue)\n' "$key"
      return 7
    fi
    if printf '%s\n' "$labels" | grep -Fxq agent-paused; then
      printf 'budget: %s stopped by control: agent-paused (a human paused this task; remove the label to resume)\n' "$key"
      return 7
    fi
  fi

  maxa="$(limit_value max_attempts_per_issue)" || exit 1
  maxr="$(limit_value max_repair_rounds)" || exit 1
  current="$(read_status "$key" || true)"
  attempts="$(jnum "${current:-}" attempts)"; [ -n "$attempts" ] || attempts=0
  repairs="$(jnum "${current:-}" repair_rounds)"; [ -n "$repairs" ] || repairs=0
  if [ "$attempts" -ge "$maxa" ]; then
    printf 'budget: %s exhausted: attempts %s/%s reached max_attempts_per_issue; a human must review before more autonomous runs\n' \
      "$key" "$attempts" "$maxa"
    return 6
  fi
  if [ "$repairs" -ge "$maxr" ]; then
    printf 'budget: %s exhausted: repair rounds %s/%s reached max_repair_rounds; a human must review before more autonomous runs\n' \
      "$key" "$repairs" "$maxr"
    return 6
  fi
  printf 'budget: %s within budget (attempts %s/%s, repairs %s/%s)\n' \
    "$key" "$attempts" "$maxa" "$repairs" "$maxr"
  return 0
}

# --- entry --------------------------------------------------------------------

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  limits) cmd_limits "$@" ;;
  limit) cmd_limit "$@" ;;
  check) cmd_check "$@" ;;
  record) cmd_record "$@" ;;
  show) cmd_show "$@" ;;
  summary) cmd_summary "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
