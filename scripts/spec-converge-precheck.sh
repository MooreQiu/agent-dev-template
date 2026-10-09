#!/usr/bin/env bash
# Workflow control adapter for the convergence precheck (issue #43).
#
# scripts/spec-converge.sh signals an undrained task queue with exit code
# 3. Mapping that to a plain step exit 0 let the converge workflow's later
# steps (agent evaluation, remediation creation, completion publication)
# run anyway, because a successful step never skips its siblings. This
# adapter turns the precheck into an explicit machine-readable outcome the
# workflow gates its later steps on:
#
#   entrypoint exit 0 -> outcome=ready    normal convergence path continues
#   entrypoint exit 3 -> outcome=deferred queue not drained; rerun later
#   anything else      -> outcome=failed  fail closed (exit code preserved)
#
# Usage:
#   scripts/spec-converge-precheck.sh <spec-path> <approved-revision> [options]
#
# Arguments and options are forwarded to scripts/spec-converge.sh verbatim;
# --precheck is appended (idempotent) so this adapter can never launch a
# full convergence run by accident. The outcome is appended to the file in
# $GITHUB_OUTPUT when set and always printed on stdout as "outcome=<value>".
#
# Exit codes: 0 = ready or deferred (inspect the outcome to decide),
# non-zero = precheck failure; the code comes from the entrypoint.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${1:-}"
OUT_FILE="${GITHUB_OUTPUT:-}"

bash "$SELF_DIR/spec-converge.sh" "$@" --precheck
rc=$?

case "$rc" in
  0) outcome=ready ;;
  3) outcome=deferred ;;
  *) outcome=failed ;;
esac

if [ -n "$OUT_FILE" ]; then
  printf 'outcome=%s\n' "$outcome" >> "$OUT_FILE"
fi
printf 'outcome=%s\n' "$outcome"

case "$outcome" in
  ready) ;;
  deferred)
    printf '::notice::Task queue for %s is not drained yet; convergence deferred, rerun after the remaining work closes.\n' "$SPEC"
    ;;
  failed)
    printf '::error::Convergence precheck failed (exit %s); failing closed.\n' "$rc"
    ;;
esac

case "$outcome" in
  ready|deferred) exit 0 ;;
  failed)         exit "$rc" ;;
esac
