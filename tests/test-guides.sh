#!/bin/sh
# Acceptance tests for issue #50: installation and operations guides.
#
# Criteria:
#   - INSTALL.md documents minimal permissions/authentication alongside
#     the existing install/config/smoke-test coverage.
#   - docs/OPERATIONS.md documents milestone vs queue semantics,
#     dependency-aware enqueueing, claim ownership, and interpreting CI
#     gate results versus review verdicts.
#   - docs/RUN_CONTROL.md documents pause/resume/cancel, budget
#     exhaustion, rejected PR recovery, stale claims, and retained
#     partial work.
#   - docs/UPGRADE.md documents version upgrade, conflict handling,
#     rollback/removal, retained user customization, and secrets.
#   - README and INSTALL cross-link the guides, and every relative link
#     target in the five documents resolves inside the repository.

set -u

cd "$(dirname "$0")/.."

failures=0

check() {
    description=$1
    shift
    if "$@"; then
        echo "ok - $description"
    else
        echo "FAIL - $description"
        failures=$((failures + 1))
    fi
}

contains() { # contains <file> <extended regex>
    grep -Eq -- "$2" "$1"
}

INSTALL=INSTALL.md
OPS=docs/OPERATIONS.md
CONTROL=docs/RUN_CONTROL.md
UPGRADE=docs/UPGRADE.md

check "INSTALL.md exists" test -f "$INSTALL"
check "operations guide exists" test -f "$OPS"
check "run control guide exists" test -f "$CONTROL"
check "upgrade guide exists" test -f "$UPGRADE"

# AC1: minimal permissions/authentication in the install manual.
if [ -f "$INSTALL" ]; then
    check "INSTALL documents minimal permissions" \
        contains "$INSTALL" 'AGENT_ALLOWED_ACTORS'
    check "INSTALL documents the workflow permission scope" \
        contains "$INSTALL" 'pull-requests: write'
    check "INSTALL documents the web toggle" \
        contains "$INSTALL" 'create and approve pull requests'
    check "INSTALL documents the smoke test exit criterion" \
        contains "$INSTALL" '--exit-status'
fi

# AC2: operations guide -- queue semantics, dependencies, claims, verdicts.
if [ -f "$OPS" ]; then
    check "operations guide separates milestone from queue eligibility" \
        contains "$OPS" 'ready-for-agent' && contains "$OPS" '[Mm]ilestone'
    check "operations guide documents p0 blocking semantics" \
        contains "$OPS" 'p0'
    check "operations guide documents the Dependencies convention" \
        contains "$OPS" '## Dependencies'
    check "operations guide requires merged PRs to unlock dependents" \
        contains "$OPS" '[Mm]erged'
    check "operations guide documents claim ownership and leases" \
        contains "$OPS" 'agent-claims' && contains "$OPS" 'lease'
    check "operations guide documents the sweep schedule" \
        contains "$OPS" '19:37'
    check "operations guide documents both verdicts" \
        contains "$OPS" 'VERDICT: APPROVE' && \
        contains "$OPS" 'VERDICT: REQUEST_CHANGES'
    check "operations guide separates CI gate from review verdict" \
        contains "$OPS" 'ci-gate' && contains "$OPS" '[Vv]erdict artifact'
    check "operations guide flags control-path PRs for manual merge" \
        contains "$OPS" 'review-verdict'
fi

# AC3: run control guide -- pause/resume/cancel, budgets, repair,
# stale claims, partial work.
if [ -f "$CONTROL" ]; then
    check "run control guide documents pause and cancel labels" \
        contains "$CONTROL" 'agent-paused' && contains "$CONTROL" 'agent-cancelled'
    check "run control guide documents budget exhaustion" \
        contains "$CONTROL" 'budgets\.json' && contains "$CONTROL" 'budget_exhausted'
    check "run control guide marks exhausted budgets blocked" \
        contains "$CONTROL" 'blocked'
    check "run control guide documents rejected PR recovery" \
        contains "$CONTROL" 'pr-repair' && contains "$CONTROL" 'agent-failed'
    check "run control guide documents stale claim reconciliation" \
        contains "$CONTROL" 'reconcile' && contains "$CONTROL" 'lease'
    check "run control guide documents the manual claim release" \
        contains "$CONTROL" -- '--remove-label agent-claimed'
    check "run control guide documents retained partial work" \
        contains "$CONTROL" 'budget_stop' && contains "$CONTROL" 'prepare'
fi

# AC4: upgrade guide -- upgrade, conflicts, rollback/removal,
# customization, secrets.
if [ -f "$UPGRADE" ]; then
    check "upgrade guide documents re-running deploy.sh" \
        contains "$UPGRADE" 'deploy\.sh'
    check "upgrade guide documents the versioned bundle path" \
        contains "$UPGRADE" 'build-bundle'
    check "upgrade guide documents preview-based conflict handling" \
        contains "$UPGRADE" '--preview'
    check "upgrade guide states existing files are skipped" \
        contains "$UPGRADE" '[Ss]kip'
    check "upgrade guide documents rollback" \
        contains "$UPGRADE" '[Rr]ollback|revert'
    check "upgrade guide documents removal commands" \
        contains "$UPGRADE" 'gh workflow disable' && \
        contains "$UPGRADE" 'gh secret remove'
    check "upgrade guide names retained user customization" \
        contains "$UPGRADE" 'project\.json'
    check "upgrade guide documents secret rotation" \
        contains "$UPGRADE" 'ANTHROPIC_AUTH_TOKEN' && \
        contains "$UPGRADE" '[Rr]otation|轮换'
fi

# AC5: cross-links and link validation across all five documents.
check "README links the operations guide" contains README.md 'docs/OPERATIONS\.md'
check "README links the run control guide" contains README.md 'docs/RUN_CONTROL\.md'
check "README links the upgrade guide" contains README.md 'docs/UPGRADE\.md'
if [ -f "$INSTALL" ]; then
    check "INSTALL links the operations guide" contains "$INSTALL" 'docs/OPERATIONS\.md'
    check "INSTALL links the run control guide" contains "$INSTALL" 'docs/RUN_CONTROL\.md'
    check "INSTALL links the upgrade guide" contains "$INSTALL" 'docs/UPGRADE\.md'
fi

for doc in "$INSTALL" "$OPS" "$CONTROL" "$UPGRADE"; do
    [ -f "$doc" ] || continue
    for target in $(grep -oE '\]\([^) ]+\)' "$doc" | sed -E 's/^\]\(([^) ]+)\)$/\1/' | sort -u); do
        case "$target" in
            http://* | https://* | '#'*) continue ;;
        esac
        path=${target%%#*}
        [ -n "$path" ] || continue
        # Relative links resolve from the document's own directory.
        case "$doc" in
            docs/*) resolved="docs/$path" ;;
            *) resolved="$path" ;;
        esac
        check "link target exists: $doc -> $path" test -e "$resolved"
    done
done

if [ "$failures" -eq 0 ]; then
    echo "all tests passed"
    exit 0
fi
echo "$failures test(s) failed"
exit 1
