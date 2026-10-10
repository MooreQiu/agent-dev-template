#!/usr/bin/env bash
# Watchdog hygiene (issue #99): scripts/agent-task.sh arms an elapsed-time
# watchdog (`sleep $MAX_ELAPSED` inside a subshell) around the harness run.
# When the harness finishes first, the parent kills only the watchdog
# subshell, so the sleep child is reparented as an orphan that inherits the
# caller's pipe fds -- with `npm test | tail` the reader then never sees EOF
# even though the suite already exited 0.
#
# The sentinel is self-produced and self-collected: the fixture declares a
# run-unique max_elapsed_seconds_per_run, the assertions match exactly that
# sleep command line, and any match is reaped afterwards, so concurrent
# suite runs cannot pollute the result and no run leaks a long sleeper.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-watchdog.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

failures=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1${2:+ -- $2}"; failures=$((failures + 1)); }
check() { # check <description> <command...>
  d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
check_rc() { # check_rc <want> <got> <description> <log>
  if [ "$2" -eq "$1" ]; then
    ok "$3"
  else
    bad "$3" "expected exit $1, got $2: $(tail -3 "$4" 2>/dev/null | tr '\n' ' ')"
  fi
}

# Run-unique watchdog budget: doubles as the orphan sentinel's match key, so
# only sleeps spawned by this very test invocation can ever match.
SEED="$((1000000 + $$))"
PATTERN="sleep ${SEED}\$"

make_fixture() { # make_fixture <dir> <max-elapsed-seconds>
  fx="$1"; elapsed="$2"
  git init -q --bare "$fx/origin.git"
  git -C "$fx/origin.git" symbolic-ref HEAD refs/heads/main
  mkdir -p "$fx/repo/scripts" "$fx/repo/.agent" "$fx/bin"
  cp "$REPO_ROOT/scripts/agent-task.sh" "$fx/repo/scripts/"
  cp "$REPO_ROOT/scripts/agent-claim.sh" "$fx/repo/scripts/"
  cp "$REPO_ROOT/scripts/agent-budget.sh" "$fx/repo/scripts/"
  printf '{ "max_elapsed_seconds_per_run": %s }\n' "$elapsed" \
    > "$fx/repo/.agent/budgets.json"
  # Stub gh at the only remote boundary: artifact verification fails
  # deterministically (no PR can exist against a bare fixture origin) and no
  # real gh call can ever leave the fixture.
  printf '#!/bin/sh\nexit 1\n' > "$fx/bin/gh"
  chmod +x "$fx/bin/gh"
  git -C "$fx/repo" init -q
  git -C "$fx/repo" config user.name watchdog-probe
  git -C "$fx/repo" config user.email watchdog-probe@invalid
  git -C "$fx/repo" add -A
  git -C "$fx/repo" commit -qm "seed: task pipeline scripts and run budget"
  git -C "$fx/repo" remote add origin "$fx/origin.git"
  git -C "$fx/repo" push -q origin HEAD:refs/heads/main
}

# --- a completed run must not leave its watchdog sleep behind -------------------
FX="$TMP/completion"
make_fixture "$FX" "$SEED"
log="$TMP/completion.log"
(
  cd "$FX/repo" && PATH="$FX/bin:$PATH" \
    bash scripts/agent-task.sh run "probe-$$" --owner "watchdog-probe-$$" \
    -- bash -c 'sleep 2; exit 0'
) > "$log" 2>&1 &
run_pid=$!

armed=""
i=0
while [ "$i" -lt 50 ]; do
  if pgrep -f "$PATTERN" >/dev/null 2>&1; then armed=1; break; fi
  i=$((i + 1))
  sleep 0.2
done
check "watchdog sleep is alive while the harness runs (fixture sanity)" \
  test -n "$armed"

wait "$run_pid"
run_rc=$?
check_rc 4 "$run_rc" "fixture run fails artifact verification as designed" "$log"

orphans="$(pgrep -f "$PATTERN" 2>/dev/null || true)"
if [ -n "$orphans" ]; then
  bad "no orphaned watchdog sleep survives a completed run" \
    "orphaned sleep pid(s): $(printf '%s' "$orphans" | tr '\n' ' ')"
else
  ok "no orphaned watchdog sleep survives a completed run"
fi
# Self-collect: even a failing (pre-fix) run must not leave its sleeper.
pkill -f "$PATTERN" 2>/dev/null || true

# --- the watchdog must still stop a runaway harness at the deadline -------------
FXB="$TMP/expiry"
make_fixture "$FXB" 1
log="$TMP/expiry.log"
start="$(date +%s)"
(
  cd "$FXB/repo" && PATH="$FXB/bin:$PATH" \
    bash scripts/agent-task.sh run "runaway-$$" --owner "watchdog-probe-$$" \
    -- bash -c 'sleep 15'
) > "$log" 2>&1
run_rc=$?
elapsed=$(( $(date +%s) - start ))
check_rc 6 "$run_rc" "runaway harness is budget-stopped at the deadline" "$log"
check "watchdog stops the runaway harness at the budget deadline" \
  test "$elapsed" -ge 1 -a "$elapsed" -le 9

if [ "$failures" -eq 0 ]; then
  echo "all tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
