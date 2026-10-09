#!/usr/bin/env bash
# Acceptance tests for issue #18 (part 1): one atomic claim protocol shared
# by every dispatch path (comments, assignments, scheduled sweep, repair
# workers), carrying an execution owner and an expiring lease, with
# reconciliation of claims abandoned by crashes and cancellation.
#
# The protocol lives in scripts/agent-claim.sh and uses git refs under
# refs/agent-claims/ as the shared registry; atomicity comes from
# compare-and-swap pushes (--force-with-lease=<ref>:<expect>), so two
# workers on two runners can never both hold the same issue.
#
# Covers:
#   - basic acquire/release/renew/status lifecycle (AC1, AC2)
#   - concurrent claims from two clones: exactly one winner (AC1)
#   - lease expiry: a stale claim can be stolen; a live one cannot (AC2)
#   - owner scoping: only the owner renews/releases (AC2)
#   - reconcile: expired claims are released with queue-repair labels;
#     succeeded claims are cleaned when the issue closed, or requeued when
#     their PR vanished; live claims are untouched (AC2)
#
# Run: bash tests/test-agent-claims.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/agent-claim.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/adt-claims.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1${2:+ -- $2}"; failures=$((failures + 1)); }
check() { # check <description> <command...>
  d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

# --- fixtures ---------------------------------------------------------------
# A bare origin plus independent runner clones, so every claim operation
# goes through the same remote round-trip a real CI runner performs.

seed_origin() { # seed_origin <name>
  d="$WORK/$1"
  mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  # Pin the bare HEAD to main regardless of the runner's init.defaultBranch
  # (CI images default to master; a dangling HEAD yields empty clones).
  git -C "$d/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$d/seed"
  printf 'fixture %s\n' "$1" > "$d/seed/README"
  git -C "$d/seed" add -A
  git -C "$d/seed" commit -qm "baseline"
  git -C "$d/seed" remote add origin "$d/origin.git"
  git -C "$d/seed" push -q origin HEAD:refs/heads/main
}

clone_runner() { # clone_runner <name> <runner>
  git clone -q "$WORK/$1/origin.git" "$WORK/$1/$2"
  git -C "$WORK/$1/$2" config user.name "$2"
  git -C "$WORK/$1/$2" config user.email "$2@example.com"
}

claim_ref_value() { # claim_ref_value <name> <key> -> sha or empty
  git ls-remote "$WORK/$1/origin.git" "refs/agent-claims/$2" \
    | sed -n "s/^\([0-9a-f]*\).*/\1/p"
}

# ===========================================================================
# AC0: the protocol script exists
# ===========================================================================
if [ ! -f "$SCRIPT" ]; then
  echo "FAIL - claim protocol script exists (scripts/agent-claim.sh)"
  echo "1 test(s) failed"
  exit 1
fi
ok "claim protocol script exists"

# ===========================================================================
# AC1/AC2: acquire, status, release lifecycle
# ===========================================================================
echo "== lifecycle"

seed_origin life
clone_runner life a
claim_rc() { # claim_rc <runner-dir> [args...]
  d="$1"; shift
  ( cd "$d" && bash "$SCRIPT" "$@" >/dev/null 2>&1 )
}

claim_rc "$WORK/life/a" acquire 18 --owner worker-a
rc=$?
check "first acquire succeeds" test "$rc" -eq 0
check "claim ref exists on origin after acquire" \
  test -n "$(claim_ref_value life 18)"

STATUS="$(cd "$WORK/life/a" && bash "$SCRIPT" status 18 2>/dev/null)"
check "status reports the owner" \
  sh -c "printf '%s' \"\$1\" | grep -Fq '\"owner\":\"worker-a\"'" sh "$STATUS"
check "status reports the lease expiry" \
  sh -c "printf '%s' \"\$1\" | grep -Fq '\"expires_at\":'" sh "$STATUS"

clone_runner life b
claim_rc "$WORK/life/b" acquire 18 --owner worker-b
rc=$?
check "second worker acquire is denied while lease is live" test "$rc" -eq 3
check "denied acquire does not steal the claim" \
  sh -c "printf '%s' \"\$1\" | grep -Fq 'worker-a'" sh "$(claim_ref_value life 18 >/dev/null; cd "$WORK/life/a" && bash "$SCRIPT" status 18 2>/dev/null)"

claim_rc "$WORK/life/b" release 18 --owner worker-b
rc=$?
check "release by a non-owner is denied" test "$rc" -ne 0
check "denied release keeps the claim" test -n "$(claim_ref_value life 18)"

claim_rc "$WORK/life/a" release 18 --owner worker-a
rc=$?
check "release by the owner succeeds" test "$rc" -eq 0
check "claim ref is gone after release" test -z "$(claim_ref_value life 18)"

# ===========================================================================
# AC1: concurrent claims -- two runners race, exactly one wins
# ===========================================================================
echo "== concurrent claims"

seed_origin race
clone_runner race a
clone_runner race b
: > "$WORK/race/rc-a"
: > "$WORK/race/rc-b"

# Both runners push at nearly the same moment; the CAS push guarantees
# exactly one create succeeds no matter how they interleave.
(
  cd "$WORK/race/a" \
    && bash "$SCRIPT" acquire 21 --owner race-a >/dev/null 2>&1
  echo $? > "$WORK/race/rc-a"
) &
(
  cd "$WORK/race/b" \
    && bash "$SCRIPT" acquire 21 --owner race-b >/dev/null 2>&1
  echo $? > "$WORK/race/rc-b"
) &
wait

RCA="$(cat "$WORK/race/rc-a")"
RCB="$(cat "$WORK/race/rc-b")"
WINS=0
[ "$RCA" -eq 0 ] && WINS=$((WINS + 1))
[ "$RCB" -eq 0 ] && WINS=$((WINS + 1))
check "exactly one concurrent acquire wins" test "$WINS" -eq 1
WINNER="$(
  ( cd "$WORK/race/a" && bash "$SCRIPT" status 21 2>/dev/null ) \
    | sed -n 's/.*"owner":"\([^"]*\)".*/\1/p'
)"
check "the registry holds the winner's owner" \
  sh -c '[ "$1" = "race-a" ] || [ "$1" = "race-b" ]' sh "$WINNER"

# ===========================================================================
# AC2: expiring leases
# ===========================================================================
echo "== lease expiry"

seed_origin lease
clone_runner lease a
clone_runner lease b

( cd "$WORK/lease/a" && AGENT_LEASE_SECONDS=1 bash "$SCRIPT" acquire 30 --owner short-lived ) >/dev/null 2>&1
check "short lease acquired" test -n "$(claim_ref_value lease 30)"
sleep 2

( cd "$WORK/lease/b" && bash "$SCRIPT" acquire 30 --owner newcomer ) >/dev/null 2>&1
check "expired claim can be stolen by a new worker" test $? -eq 0
STEAL_OWNER="$(
  ( cd "$WORK/lease/b" && bash "$SCRIPT" status 30 2>/dev/null ) \
    | sed -n 's/.*"owner":"\([^"]*\)".*/\1/p'
)"
check "stolen claim carries the new owner" test "$STEAL_OWNER" = "newcomer"

( cd "$WORK/lease/a" && bash "$SCRIPT" renew 30 --owner short-lived ) >/dev/null 2>&1
check "renewal by the previous owner is denied after the steal" test $? -ne 0

( cd "$WORK/lease/b" && bash "$SCRIPT" renew 30 --owner newcomer ) >/dev/null 2>&1
check "renewal by the current owner succeeds" test $? -eq 0

# ===========================================================================
# AC2: reconcile abandoned claims
# ===========================================================================
echo "== reconcile"

MOCK_BIN="$WORK/mock-bin"
GH_LOG="$WORK/gh.log"
GH_STATE="$WORK/gh-state"
mkdir -p "$MOCK_BIN" "$GH_STATE/issue" "$GH_STATE/pr"
export GH_LOG GH_STATE
cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
cmd="${1:-} ${2:-}"
case "$cmd" in
  "issue view")
    n="$3"
    cat "$GH_STATE/issue/$n.json"
    exit 0
    ;;
  "pr view")
    branch="$3"
    if [ -f "$GH_STATE/pr/$branch.json" ]; then
      cat "$GH_STATE/pr/$branch.json"
      exit 0
    fi
    echo "no pull request found for $branch" >&2
    exit 1
    ;;
  "issue edit"|"issue comment"|"pr edit"|"pr create")
    exit 0
    ;;
esac
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"
export PATH="$MOCK_BIN:$PATH"
export GITHUB_REPOSITORY=acme/fixture

issue_json() { # issue_json <n> <state>
  printf '{"number":%s,"title":"fixture issue %s","state":"%s"}\n' "$1" "$1" "$2" \
    > "$GH_STATE/issue/$1.json"
}

seed_origin rec
clone_runner rec a
clone_runner rec repair

# (a) expired foreign claim -> released, queue-repair labels applied
: > "$GH_LOG"
issue_json 40 open
( cd "$WORK/rec/a" && AGENT_LEASE_SECONDS=1 bash "$SCRIPT" acquire 40 --owner crashed-worker ) >/dev/null 2>&1
sleep 2
( cd "$WORK/rec/repair" && bash "$SCRIPT" reconcile ) > "$WORK/rec/reconcile.log" 2>&1
check "reconcile succeeds" test $? -eq 0
check "reconcile releases the expired claim" test -z "$(claim_ref_value rec 40)"
check "reconcile removes the agent-claimed label" \
  sh -c 'grep -Fq -- "--remove-label agent-claimed" "$1"' sh "$GH_LOG"
check "reconcile requeues with agent-failed" \
  sh -c 'grep -Fq -- "--add-label agent-failed" "$1"' sh "$GH_LOG"
check "reconcile comments on the abandoned issue" \
  sh -c 'grep -Fq "issue comment 40" "$1"' sh "$GH_LOG"

# (b) succeeded claim + closed issue -> registry cleaned
: > "$GH_LOG"
issue_json 41 closed
(
  cd "$WORK/rec/a" \
    && bash "$SCRIPT" acquire 41 --owner done-worker >/dev/null 2>&1 \
    && bash "$SCRIPT" update 41 --owner done-worker --field status=succeeded \
      --field branch=agent/issue-41 --field pr=9 >/dev/null 2>&1
)
check "succeeded claim recorded" test -n "$(claim_ref_value rec 41)"
( cd "$WORK/rec/repair" && bash "$SCRIPT" reconcile ) >/dev/null 2>&1
check "reconcile deletes a succeeded claim once the issue is closed" \
  test -z "$(claim_ref_value rec 41)"

# (c) succeeded claim + vanished PR + open issue -> requeued
: > "$GH_LOG"
issue_json 42 open
(
  cd "$WORK/rec/a" \
    && bash "$SCRIPT" acquire 42 --owner done-worker >/dev/null 2>&1 \
    && bash "$SCRIPT" update 42 --owner done-worker --field status=succeeded \
      --field branch=agent/issue-42 --field pr=10 >/dev/null 2>&1
)
( cd "$WORK/rec/repair" && bash "$SCRIPT" reconcile ) >/dev/null 2>&1
check "reconcile requeues a succeeded claim whose PR vanished" \
  test -z "$(claim_ref_value rec 42)"
check "vanished-PR repair labels agent-failed" \
  sh -c 'grep -Fq -- "--add-label agent-failed" "$1"' sh "$GH_LOG"

# (d) live claim -> untouched
: > "$GH_LOG"
issue_json 43 open
( cd "$WORK/rec/a" && bash "$SCRIPT" acquire 43 --owner live-worker ) >/dev/null 2>&1
( cd "$WORK/rec/repair" && bash "$SCRIPT" reconcile ) >/dev/null 2>&1
check "reconcile leaves a live claim alone" test -n "$(claim_ref_value rec 43)"
check "reconcile performs no gh mutations for a live claim" \
  sh -c '! grep -Eq "issue (edit|comment)" "$1"' sh "$GH_LOG"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
