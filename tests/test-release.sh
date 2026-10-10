#!/bin/sh
# Acceptance tests for issue #53: prepare the v0.1 release and support policy.
#
# Criteria:
#   - docs/RELEASE_NOTES_v0.1.0.md is a complete, reviewable draft: tested
#     capabilities, known limitations, supported runtime/harness combinations,
#     required accounts/permissions, installation and verification
#     instructions, feedback entrypoints, and trial expectations.
#   - docs/RELEASE.md documents the versioning policy (the release version
#     lands only via build-bundle.sh --version stamping; the repository's
#     package metadata pair stays consistent), the support matrix and
#     lifecycle, security/cost responsibilities, a release checklist linking
#     real validation evidence, and exact publication instructions; the
#     publication itself stays a separate, explicitly authorized action.
#   - Only supported behavior is claimed: experimental routes are listed as
#     unsupported instead of being promoted.
#   - package.json and package-lock.json version fields agree with each
#     other (the shipped pair is stamped consistently at bundle build time).
#   - Every relative link target in the two documents resolves in the repo.

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

contains_all() { # contains_all <file> <regex>... -- every regex must match
    file=$1
    shift
    for re in "$@"; do
        grep -Eq -- "$re" "$file" || return 1
    done
}

no_match() { # no_match <file> <extended regex>
    ! grep -Eq -- "$2" "$1"
}

NOTES=docs/RELEASE_NOTES_v0.1.0.md
POLICY=docs/RELEASE.md

check "release notes draft exists" test -f "$NOTES"
check "release and support policy exists" test -f "$POLICY"

if [ -f "$NOTES" ]; then
    # The notes are a published artifact: English prose only, no placeholders.
    if LC_ALL=C grep -q '[^ -~]' "$NOTES"; then
        echo "FAIL - release notes are ASCII-only English prose"
        failures=$((failures + 1))
    else
        echo "ok - release notes are ASCII-only English prose"
    fi
    check "release notes state the version" contains "$NOTES" '0\.1\.0'
    check "release notes mark a trial release" contains "$NOTES" '[Tt]rial'
    check "release notes list tested capabilities" \
        contains "$NOTES" '^#+ .*[Tt]ested capabilities'
    check "release notes list known limitations" \
        contains "$NOTES" '^#+ .*[Kk]nown limitations'
    check "release notes list supported combinations" \
        contains "$NOTES" '^#+ .*[Ss]upported'
    check "release notes list required accounts and permissions" \
        contains "$NOTES" '^#+ .*([Aa]ccounts|[Pp]ermissions)'
    check "release notes document installation" \
        contains "$NOTES" '^#+ .*[Ii]nstallation'
    check "release notes give feedback entrypoints" \
        contains "$NOTES" '^#+ .*[Ff]eedback'
    check "release notes give the security reporting channel" \
        contains "$NOTES" '[Ss]ecurity'
    check "release notes state the private-repository branch-protection limitation" \
        contains "$NOTES" '[Bb]ranch protection'
    check "release notes reference the tooling pin source" \
        contains "$NOTES" '\.agent/project\.json'
    check "release notes carry no unresolved placeholders" \
        no_match "$NOTES" 'TODO|TBD|FIXME|<revision>|<version>'
    check "release notes carry no publication commands" \
        no_match "$NOTES" 'gh release create|git push.*tag'
fi

if [ -f "$POLICY" ]; then
    check "policy documents the trial-release expectations" \
        contains "$POLICY" '[Tt]rial'
    check "policy documents version stamping at bundle build" \
        contains "$POLICY" 'build-bundle'
    check "policy tracks the lockfile stamping follow-up (#86)" \
        contains "$POLICY" '#86'
    check "policy does not overclaim bundle lockfile stamping" \
        no_match "$POLICY" '盖进.*package\.json` 与 `package-lock\.json'
    check "policy covers the repository package metadata pair" \
        contains "$POLICY" 'package-lock\.json'
    check "policy requires package.json and package-lock.json agreement" \
        contains "$POLICY" 'agree|一致'
    check "policy separates the runtime pin from the release version" \
        contains "$POLICY" 'runtime\.version'
    check "policy documents supported install paths" \
        contains "$POLICY" 'setup\.sh'
    check "policy documents the deploy install path" \
        contains "$POLICY" 'deploy\.sh'
    check "policy lists unsupported routes" \
        contains "$POLICY" '[Nn]ot supported|不支持'
    check "policy marks GitHub Enterprise unsupported" \
        contains "$POLICY" 'GitHub Enterprise'
    check "policy marks self-hosted runners unsupported" \
        contains "$POLICY" '[Ss]elf-hosted'
    check "policy links the upgrade path" contains "$POLICY" 'UPGRADE\.md'
    check "policy documents feedback entrypoints" \
        contains "$POLICY" 'ISSUE_TEMPLATE|issue template|模板'
    check "policy keeps security reports off public issues" \
        contains_all "$POLICY" '[Ss]ecurity' '公开|public'
    check "policy documents secret rotation responsibility" \
        contains "$POLICY" '[Rr]otation|轮换'
    check "policy documents untrusted issue/PR bodies" \
        contains "$POLICY" '不可信|untrusted'
    check "policy documents cost responsibility" \
        contains "$POLICY" '[Cc]ost|费用|成本'
    check "policy documents run budgets" contains "$POLICY" 'budgets\.json'
    check "policy links the lifecycle acceptance evidence" \
        contains "$POLICY" 'test-e2e-lifecycle'
    check "policy links the portability evidence" \
        contains "$POLICY" 'test-portability'
    check "policy links the clean-installation evidence" \
        contains "$POLICY" 'test-install-verify'
    check "policy links the bundle checksum evidence" \
        contains "$POLICY" 'test-bundle'
    check "policy links the documentation-validation evidence" \
        contains "$POLICY" 'test-guides'
    check "policy requires a full green suite on the release revision" \
        contains "$POLICY" 'npm test'
    check "policy names the exact release assets" \
        contains "$POLICY" 'manifest\.txt'
    check "policy pins the build to an immutable revision" \
        contains "$POLICY" '\-\-revision'
    check "policy gives exact publication instructions" \
        contains "$POLICY" 'gh release create'
    check "policy requires explicit authorization to publish" \
        contains "$POLICY" '[Aa]uthoriz|授权'
    check "policy forbids publishing during preparation" \
        contains "$POLICY" '不发布|[Nn]ever publish|[Dd]oes not publish|不得'
fi

# Version consistency: the repository's package metadata pair must agree with
# each other; the release version itself is stamped into the bundle copy by
# build-bundle.sh, never committed here.
pkg_ver="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' package.json | sed -n 1p)"
lock_top="$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' package-lock.json | sed -n 1p)"
lock_root="$(sed -n 's/^      "version": "\([^"]*\)".*/\1/p' package-lock.json | sed -n 1p)"
check "package.json declares a version" sh -c '[ -n "$1" ]' sh "$pkg_ver"
check "package-lock.json top-level version matches package.json" \
    sh -c '[ "$1" = "$2" ]' sh "$pkg_ver" "$lock_top"
check "package-lock.json packages version matches package.json" \
    sh -c '[ "$1" = "$2" ]' sh "$pkg_ver" "$lock_root"

# Cross-links from the existing front-door documents.
check "README links the release and support policy" \
    contains README.md 'docs/RELEASE\.md'
check "BUNDLE.md links the release process" contains docs/BUNDLE.md 'RELEASE\.md'

# Every relative link target in the new documents resolves inside the repo.
for doc in "$POLICY" "$NOTES"; do
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
