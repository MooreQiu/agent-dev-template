#!/bin/sh
# Guard: shell scripts in tests/ and scripts/ must run identically on BSD
# (macOS) and GNU (Linux) userland -- CI runs on ubuntu-latest while local
# development happens on macOS, so single-platform constructs are bugs.
#
# Criteria:
#   - No BSD-only sed in-place edits (the GNU utility would parse the empty
#     suffix argument as the sed script and silently no-op the edit).
#   - No single-platform utility flags (GNU-only readlink/grep options,
#     BSD/GNU-only stat options).

set -u

SELF="$(basename "$0")"
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

# Built via variables so this guard does not match its own source.
BSD_SED_INPLACE="sed -i ''"
PLATFORM_FLAGS='readlink -f|grep -P|stat -f|stat -c'

sed_bad=""
flag_bad=""
for f in tests/*.sh scripts/*.sh; do
    [ "${f##*/}" = "$SELF" ] && continue
    if grep -Fq -- "$BSD_SED_INPLACE" "$f"; then
        sed_bad="$sed_bad $f"
    fi
    if grep -Eq -- "$PLATFORM_FLAGS" "$f"; then
        flag_bad="$flag_bad $f"
    fi
done

check "shell scripts contain no BSD-only sed in-place edits" \
    test -z "$sed_bad"
check "shell scripts contain no single-platform utility flags" \
    test -z "$flag_bad"

[ -z "$sed_bad$flag_bad" ] || echo "violations:$sed_bad$flag_bad" >&2

if [ "$failures" -eq 0 ]; then
    echo "all tests passed"
    exit 0
fi
echo "$failures test(s) failed"
exit 1
