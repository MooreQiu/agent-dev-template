#!/usr/bin/env bash
# Acceptance tests for issue #32: the GitHub App setup runbook must document
# the Workflows permission and its failure mode.
#
# Criteria covered:
#   - docs/GITHUB_APP_SETUP.md exists (the setup runbook)
#   - repository permission table includes Workflows: Read & write
#   - failure mode documented: without the permission GitHub refuses
#     App-side merges of PRs touching .github/workflows/*
#   - runbook explains where to grant the permission (App settings path)
#   - smoke-test section: a workflow-touching PR merge validates it
#
# The behavioral auth tests (token minting, masking, workflow wiring) live on
# the issue #13 branch (PR #26) together with scripts/app-auth.sh; this file
# lands the runbook-content pins added by issue #32 and merges with those
# once PR #26 lands.
#
# Run: bash tests/test-app-auth.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS="$REPO_ROOT/docs/GITHUB_APP_SETUP.md"

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+ -- $2}"; failures=$((failures + 1)); }

contains() { # contains <fixed string> <description>
  grep -Fq -- "$1" "$DOCS" \
    && pass "$2" \
    || fail "$2" "not found in docs/GITHUB_APP_SETUP.md: $1"
}

[ -f "$DOCS" ] \
  && pass "docs/GITHUB_APP_SETUP.md exists" \
  || fail "docs/GITHUB_APP_SETUP.md exists" "file not found"

if [ -f "$DOCS" ]; then
  # --- AC: permission table includes Workflows: Read & write ---
  grep -Eq '\|[[:space:]]*Workflows[[:space:]]*\|[[:space:]]*Read & write' "$DOCS" \
    && pass "permission table lists Workflows: Read & write" \
    || fail "permission table lists Workflows: Read & write" \
      "expected a '| Workflows | Read & write | ... |' table row"

  # --- AC: failure mode documented (merge refused on workflow PRs) ---
  contains 'refusing to allow a GitHub App to create or update workflow' \
    "failure mode quotes GitHub's merge refusal error"
  contains 'without `workflows` permission' \
    "failure mode names the missing workflows permission"

  # --- AC: exact path to grant the permission on an existing App ---
  contains 'Workflows 设为 Read and write' \
    "runbook gives the App settings path to grant Workflows"

  # --- AC: smoke test validates the permission via a workflow PR ---
  contains '端到端 smoke test' \
    "runbook has an end-to-end smoke test section"
  contains '触及 `.github/workflows/*` 的 PR' \
    "smoke test merges a workflow-touching PR to validate Workflows"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
