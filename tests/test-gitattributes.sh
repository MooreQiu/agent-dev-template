#!/bin/sh
# Acceptance tests for issue #5: add .gitattributes for LF normalization.
#
# Criteria:
#   - A root .gitattributes exists.
#   - A rule applying to all files normalizes text and forces LF eol.

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

check "root .gitattributes exists" test -f .gitattributes

# Verify the rule is effective for a text file instead of matching its exact
# spelling, so equivalent configurations pass too.
attrs=$(git check-attr text eol -- README.md)

check "all files are normalized as text" \
    sh -c 'printf "%s\n" "$1" | grep -Eq ": text: (auto|set)$"' sh "$attrs"

check "all files use LF line endings" \
    sh -c 'printf "%s\n" "$1" | grep -Eq ": eol: lf$"' sh "$attrs"

if [ "$failures" -eq 0 ]; then
    echo "all tests passed"
    exit 0
fi
echo "$failures test(s) failed"
exit 1
