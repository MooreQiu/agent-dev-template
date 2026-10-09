#!/bin/sh
# Acceptance tests for issue #49: README as the distribution front door.
#
# Criteria:
#   - README.md exists and uses English prose (ASCII-only content).
#   - Restructured around purpose, suitable users, responsibilities,
#     lifecycle, prerequisites, and supported scope.
#   - Provides new-repository and existing-repository entrypoints that
#     lead to installation, configuration, one task, and observable
#     results.
#   - Documents ready-for-agent eligibility (claims, dependencies,
#     milestone membership is not eligibility) and review verdicts,
#     distinguishing review workflow success from approval.
#   - Every relative link target used in README.md exists in the repo.

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

DOC=README.md

check "root README.md exists" test -f "$DOC"

if [ -f "$DOC" ]; then
    # AC5: English repository prose (no non-ASCII bytes anywhere).
    if LC_ALL=C grep -q '[^ -~]' "$DOC"; then
        echo "FAIL - README is ASCII-only English prose"
        failures=$((failures + 1))
    else
        echo "ok - README is ASCII-only English prose"
    fi

    # AC1: structure -- purpose, users, responsibilities, lifecycle,
    # prerequisites, supported scope.
    check "documents purpose" contains "$DOC" '^#+ .*(Purpose|What this template is)'
    check "documents suitable users" contains "$DOC" '^#+ .*(Who this is for|Suitable users)'
    check "documents responsibilities" contains "$DOC" '^#+ .*(Who does what|Responsibilities)'
    check "documents the lifecycle" contains "$DOC" '^#+ .*Lifecycle'
    check "documents prerequisites" contains "$DOC" '^#+ .*Prerequisites'
    check "documents supported scope" contains "$DOC" '^#+ .*Supported scope'

    # AC2: both repository entrypoints and the first-task loop.
    check "documents the template route for new repositories" \
        contains "$DOC" 'template[[:space:]]+MooreQiu/agent-dev-template'
    check "documents the deploy route for existing repositories" \
        contains "$DOC" '\./deploy\.sh'
    check "documents setup.sh configuration" contains "$DOC" '\./setup\.sh'
    check "documents creating a first task" contains "$DOC" 'gh issue create'
    check "documents the @claude trigger" contains "$DOC" '@claude'
    check "documents observing the run" contains "$DOC" 'gh run watch'
    check "documents the model auth prerequisite" contains "$DOC" 'ANTHROPIC_AUTH_TOKEN'

    # AC3: queue eligibility, claims, dependencies, verdicts.
    check "documents the ready-for-agent queue" contains "$DOC" 'ready-for-agent'
    check "documents the claim label" contains "$DOC" 'agent-claimed'
    check "documents the blocked label" contains "$DOC" 'blocked'
    check "documents the Dependencies section convention" contains "$DOC" '## Dependencies'
    check "distinguishes milestone membership from eligibility" \
        contains "$DOC" 'membership'
    check "documents the approve verdict" contains "$DOC" 'VERDICT: APPROVE'
    check "documents the request-changes verdict" contains "$DOC" 'VERDICT: REQUEST_CHANGES'
    check "distinguishes workflow success from approval" \
        contains "$DOC" 'not approval'
    check "documents fail-closed merges" contains "$DOC" 'fails closed'

    # AC4: links out to operations, troubleshooting, upgrade/removal,
    # security, cost, and limitations.
    check "links the operations manual" contains "$DOC" 'INSTALL\.md'
    check "links the GitHub App runbook" contains "$DOC" 'GITHUB_APP_SETUP'
    check "documents upgrade behavior" contains "$DOC" '[Uu]pgrade'
    check "documents removal behavior" contains "$DOC" '[Rr]emoval'
    check "documents known limitations" contains "$DOC" '[Kk]nown limitations'

    # AC5: every relative link target resolves inside the repo.
    for target in $(sed -n 's/.*](\([^) ]*\)).*/\1/p' "$DOC" | sort -u); do
        case "$target" in
            http://* | https://* | '#'*) continue ;;
        esac
        path=${target%%#*}
        [ -n "$path" ] || continue
        check "link target exists: $path" test -e "$path"
    done
fi

if [ "$failures" -eq 0 ]; then
    echo "all tests passed"
    exit 0
fi
echo "$failures test(s) failed"
exit 1
