#!/bin/sh
# Acceptance tests for issue #7: add CONTRIBUTING.md documenting the workflow.
#
# Criteria:
#   - A root CONTRIBUTING.md exists.
#   - It documents the work queue labels
#     (ready-for-agent / agent-claimed / agent-failed / blocked / trivial).
#   - It documents the three trigger methods
#     (@claude comment / assignment / nightly sweep).
#   - It documents TDD requirements and PR conventions
#     (template, Closes #N, verification evidence).
#   - Its content stays consistent with AGENTS.md (no label drift).

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
    grep -Eq "$2" "$1"
}

DOC=CONTRIBUTING.md

check "root CONTRIBUTING.md exists" test -f "$DOC"

if [ -f "$DOC" ]; then
    # AC1: work queue label system.
    for label in ready-for-agent agent-claimed agent-failed blocked trivial; do
        check "documents label '$label'" contains "$DOC" "$label"
    done

    # AC2: three trigger methods.
    check "documents @claude comment trigger" contains "$DOC" '@claude'
    check "documents assignment trigger" contains "$DOC" '指派|assigned|assignee'
    check "documents nightly sweep trigger" contains "$DOC" 'sweep|每晚'

    # AC3: TDD requirements and PR conventions.
    check "documents TDD requirement" contains "$DOC" 'TDD'
    check "documents red/green cycle" contains "$DOC" '红|red'
    check "documents PR template" contains "$DOC" 'PULL_REQUEST_TEMPLATE|PR 模板|模板'
    check "documents Closes #N linkage" contains "$DOC" 'Closes #'
    check "documents verification evidence in PR" contains "$DOC" '验证'

    # AC4: every label documented in AGENTS.md also appears here, so the two
    # files cannot drift apart on the queue vocabulary.
    for label in $(sed -n 's/^| `\([a-z0-9-]*\)` |.*/\1/p' AGENTS.md); do
        check "consistent with AGENTS.md on '$label'" contains "$DOC" "$label"
    done
fi

if [ "$failures" -eq 0 ]; then
    echo "all tests passed"
    exit 0
fi
echo "$failures test(s) failed"
exit 1
