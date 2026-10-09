#!/usr/bin/env bash
# Acceptance tests for issue #36: the reviewer bot login must be a per-
# deployment configuration (the AGENT_REVIEWER_BOT_LOGIN repository Actions
# variable), never a hardcoded App name. GitHub App names occupy a global,
# site-wide namespace, so any fixed name is already taken for almost every
# deployment of this template.
#
# Since issue #19 merge authorization is bound to the structured verdict
# artifact; the allowlist resolved by scripts/reviewer-identity.sh is for
# display/filtering (attributing audit-trail comments) only and fails
# closed:
#   - a well-formed variable login joins the allowlist (exact match)
#   - unset/empty variable -> github-actions[bot] only
#   - unknown bots rejected; no loose [bot]-suffix or case-insensitive match
#   - malformed variable ignored with a warning; default allowlist only
#
# Run: bash tests/test-reviewer-identity.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/reviewer-identity.sh"
WF="$REPO_ROOT/.github/workflows/pr-review.yml"

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+ -- $2}"; failures=$((failures + 1)); }

check() { # check <description> <command> [args...]
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    failures=$((failures + 1))
  fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-test-revid36.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

OUT=""
RC=0

run_list() { # run_list <variable-value|-> ("-" = unset)
  : >"$TMP/err.txt"
  if [ "$1" = "-" ]; then
    OUT=$(env -u AGENT_REVIEWER_BOT_LOGIN bash "$SCRIPT" list 2>"$TMP/err.txt")
  else
    OUT=$(AGENT_REVIEWER_BOT_LOGIN="$1" bash "$SCRIPT" list 2>"$TMP/err.txt")
  fi
  RC=$?
}

run_check() { # run_check <variable-value|-> <login>
  if [ "$1" = "-" ]; then
    OUT=$(env -u AGENT_REVIEWER_BOT_LOGIN bash "$SCRIPT" check "$2" 2>"$TMP/err.txt")
  else
    OUT=$(AGENT_REVIEWER_BOT_LOGIN="$1" bash "$SCRIPT" check "$2" 2>"$TMP/err.txt")
  fi
  RC=$?
}

list_is() { # list_is <expected-login>... -- OUT must be exactly these lines
  local expected
  expected="$(printf '%s\n' "$@")"
  [ "$OUT" = "$expected" ]
}

CFG="acme-deploy-bot[bot]"
DEFAULT="github-actions[bot]"

# --- AC: any user-chosen App name works via the variable ---------------------

echo "== variable-driven login"

run_list "$CFG"
check "list exits 0 with a configured login" sh -c '[ "$1" = 0 ]' sh "$RC"
check "allowlist carries the default plus the configured login" list_is \
  "$DEFAULT" "$CFG"

run_check "$CFG" "$CFG"
check "configured reviewer login is accepted (exact match)" \
  sh -c '[ "$1" = 0 ]' sh "$RC"

run_check "$CFG" "$DEFAULT"
check "default login stays accepted alongside the configured one" \
  sh -c '[ "$1" = 0 ]' sh "$RC"

# 39 chars is the longest GitHub login slug; still valid
SLUG39="$(printf 'b%.0s' $(seq 39))"
run_list "$SLUG39[bot]"
check "a 39-char slug passes validation" list_is "$DEFAULT" "$SLUG39[bot]"

# --- AC: unset / empty variable falls back to the default only ---------------

echo "== default fallback"

run_list "-"
check "unset variable exits 0" sh -c '[ "$1" = 0 ]' sh "$RC"
check "unset variable leaves github-actions[bot] as the only entry" \
  list_is "$DEFAULT"

run_list ""
check "empty variable leaves github-actions[bot] as the only entry" \
  list_is "$DEFAULT"

run_check "-" "$DEFAULT"
check "default login accepted without the variable" \
  sh -c '[ "$1" = 0 ]' sh "$RC"

run_check "-" "$CFG"
check "configured-style login rejected when the variable is unset" \
  sh -c '[ "$1" = 1 ]' sh "$RC"

run_list "$DEFAULT"
check "variable equal to the default does not duplicate the entry" \
  list_is "$DEFAULT"

# --- AC: unknown bots rejected; matching stays exact --------------------------

echo "== unknown bots rejected"

run_check "$CFG" "other-app[bot]"
check "an unrelated app bot is rejected" sh -c '[ "$1" = 1 ]' sh "$RC"

run_check "$CFG" "$DEFAULT-x"
check "near-miss of the default is rejected" sh -c '[ "$1" = 1 ]' sh "$RC"

run_check "$CFG" "acme-deploy-bot"
check "login without the [bot] suffix is rejected (no loose matching)" \
  sh -c '[ "$1" = 1 ]' sh "$RC"

run_check "$CFG" "ACME-DEPLOY-BOT[bot]"
check "matching is case-sensitive" sh -c '[ "$1" = 1 ]' sh "$RC"

run_check "$CFG" "x$CFG"
check "prefixed look-alike is rejected" sh -c '[ "$1" = 1 ]' sh "$RC"

OUT=$(AGENT_REVIEWER_BOT_LOGIN="$CFG" bash "$SCRIPT" 2>/dev/null)
check "no subcommand is a usage error" sh -c '[ "$1" = 2 ]' sh "$?"

OUT=$(AGENT_REVIEWER_BOT_LOGIN="$CFG" bash "$SCRIPT" frobnicate 2>/dev/null)
check "unknown subcommand is a usage error" sh -c '[ "$1" = 2 ]' sh "$?"

OUT=$(AGENT_REVIEWER_BOT_LOGIN="$CFG" bash "$SCRIPT" check 2>/dev/null)
check "check without a login is a usage error" sh -c '[ "$1" = 2 ]' sh "$?"

OUT=$(AGENT_REVIEWER_BOT_LOGIN="$CFG" bash "$SCRIPT" list extra 2>/dev/null)
check "list rejects extra arguments" sh -c '[ "$1" = 2 ]' sh "$?"

# --- AC: malformed variable ignored, fail closed ------------------------------

echo "== malformed variable"

SLUG40="$(printf 'a%.0s' $(seq 40))"
for bad in \
  "notabot" \
  "my bot[bot]" \
  "Acme Bot[bot]" \
  "UPPER-bot[bot]" \
  "acme[bot]x" \
  "[bot]" \
  "-acme[bot]" \
  "a_b[bot]" \
  " acme[bot]" \
  "acme[bot] " \
  "$SLUG40[bot]" \
  "github-actions"; do
  run_list "$bad"
  check "malformed value ($bad) leaves the default allowlist only" list_is "$DEFAULT"
  check "malformed value ($bad) is never admitted" \
    sh -c 'AGENT_REVIEWER_BOT_LOGIN="$1" bash "$2" check "$1" >/dev/null 2>&1; [ "$?" = 1 ]' \
    sh "$bad" "$SCRIPT"
  check "malformed value ($bad) still leaves the default accepted" \
    sh -c 'AGENT_REVIEWER_BOT_LOGIN="$1" bash "$2" check "$3" >/dev/null 2>&1; [ "$?" = 0 ]' \
    sh "$bad" "$SCRIPT" "$DEFAULT"
done

run_list "notabot"
check "a malformed variable logs a warning naming the variable" \
  sh -c 'grep -q "AGENT_REVIEWER_BOT_LOGIN" "$1"' sh "$TMP/err.txt"

# --- config layer: no hardcoded deployment login survives ---------------------

echo "== config layer"

check "resolver script exists" test -f "$SCRIPT"
check "resolver script is executable" test -x "$SCRIPT"
check "review workflow maps the repo variable into env" \
  sh -c 'grep -Fq "vars.AGENT_REVIEWER_BOT_LOGIN" "$1"' sh "$WF"
check "review-verdict.sh references the variable (no fixed App name)" \
  sh -c 'grep -Fq "AGENT_REVIEWER_BOT_LOGIN" "$1"' \
  sh "$REPO_ROOT/scripts/review-verdict.sh"
check "review-verdict.sh no longer hardcodes a deployment's App login" \
  sh -c '! grep -Fq "mooreqiu-agent-dev-bot" "$1"' \
  sh "$REPO_ROOT/scripts/review-verdict.sh"
check "authorization stays artifact-based (no comment lookup in the decider)" \
  sh -c '! grep -Eq "issues/.+/comments" "$1"' \
  sh "$REPO_ROOT/scripts/review-verdict.sh"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
