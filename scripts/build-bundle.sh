#!/usr/bin/env bash
# Build a versioned distribution bundle of this template (issue #51).
#
# Usage:
#   scripts/build-bundle.sh --version <X.Y.Z> [options]
#
# Options:
#   --version X.Y.Z   bundle version, required (leading "v" tolerated)
#   --revision SHA    immutable source commit (full SHA; default: HEAD of --source)
#   --source DIR      repository to package (default: this script's repository)
#   --output DIR      artifact directory, created if needed (default: dist)
#   --notes FILE      use FILE as the release-notes body instead of the skeleton
#
# Produces in --output:
#   agent-dev-template-<version>.tar.gz            compressed bundle
#   agent-dev-template-<version>.manifest.txt     version/revision + per-file sha256
#   agent-dev-template-<version>.sha256            checksum for `sha256sum -c`
#   agent-dev-template-<version>.release-notes.md  release-notes input
#
# Contents are taken from `git archive <revision>` filtered through the
# explicit allowlist (scripts/bundle-allowlist.txt) minus the deny list below,
# so git internals, worktrees, local settings, secrets, environment files,
# run logs and generated evidence never enter the bundle -- even when present
# on disk, and even when committed by accident.
#
# This command only BUILDS. It never publishes and never creates a release.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST="$SELF_DIR/bundle-allowlist.txt"
PRODUCT="agent-dev-template"

usage() {
  sed -n '/^# Usage:/,/^# Produces/p' "$0" | sed '1d;$d' | sed 's/^# \{0,1\}//'
}

die() { printf 'build-bundle: %s\n' "$1" >&2; exit 1; }

sha256_of() { # sha256_of <file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

VERSION="" REVISION="" SOURCE="" OUTPUT="" NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    --revision) [ $# -ge 2 ] || die "--revision needs a value"; REVISION="$2"; shift 2 ;;
    --source) [ $# -ge 2 ] || die "--source needs a value"; SOURCE="$2"; shift 2 ;;
    --output) [ $# -ge 2 ] || die "--output needs a value"; OUTPUT="$2"; shift 2 ;;
    --notes) [ $# -ge 2 ] || die "--notes needs a value"; NOTES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# --- validate inputs --------------------------------------------------------
[ -n "$VERSION" ] || die "--version is required"
case "$VERSION" in v*) VERSION="${VERSION#v}" ;; esac
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z]+)*$' \
  || die "invalid version '$VERSION' (expected X.Y.Z)"

[ -f "$ALLOWLIST" ] || die "allowlist not found: $ALLOWLIST"
[ -n "$SOURCE" ] || SOURCE="$(cd "$SELF_DIR/.." && pwd)"
git -C "$SOURCE" rev-parse --git-dir >/dev/null 2>&1 \
  || die "--source is not a git repository: $SOURCE"

if [ -z "$REVISION" ]; then
  REVISION="$(git -C "$SOURCE" rev-parse HEAD)"
fi
# Only a full commit SHA is accepted: tags and branches are mutable, a SHA
# pins the exact tree the bundle was built from.
printf '%s\n' "$REVISION" | grep -Eq '^[0-9a-f]{40}$|^[0-9a-f]{64}$' \
  || die "revision must be a full commit SHA (got '$REVISION')"
git -C "$SOURCE" cat-file -e "${REVISION}^{commit}" 2>/dev/null \
  || die "revision $REVISION does not exist in $SOURCE"

[ -n "$OUTPUT" ] || OUTPUT="dist"
mkdir -p "$OUTPUT"
case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$(pwd)/$OUTPUT" ;;
esac
if [ -n "$NOTES" ] && [ ! -f "$NOTES" ]; then
  die "--notes file not found: $NOTES"
fi

NAME="$PRODUCT-$VERSION"
TARBALL="$OUTPUT/$NAME.tar.gz"
MANIFEST="$OUTPUT/$NAME.manifest.txt"
CHECKSUM="$OUTPUT/$NAME.sha256"
NOTES_OUT="$OUTPUT/$NAME.release-notes.md"

# --- stage exactly the allowlisted tree from the pinned revision ------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bundle-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
EXTRACT="$WORK/extract"
BUNDLE="$WORK/$NAME"
mkdir -p "$EXTRACT" "$BUNDLE"

git -C "$SOURCE" archive --format=tar "$REVISION" | tar -x -C "$EXTRACT"

missing=""
while IFS= read -r entry; do
  case "$entry" in
    ''|'#'*) continue ;;
  esac
  entry="${entry%/}"
  if [ -e "$EXTRACT/$entry" ]; then
    mkdir -p "$BUNDLE/$(dirname "$entry")"
    mv "$EXTRACT/$entry" "$BUNDLE/$entry"
  else
    missing="$missing$entry
"
  fi
done < "$ALLOWLIST"
rm -rf "$EXTRACT"
[ -z "$missing" ] || die "allowlisted path(s) missing at $REVISION:
$missing"

# --- deny list: safety net on top of the allowlist --------------------------
# The allowlist already cannot pick up untracked local junk (we package a git
# revision, not the working tree), and tests/ etc. are simply not allowlisted.
# This pass removes anything that must never ship even if someone commits it.
(
  cd "$BUNDLE"
  find . \( \
    -name '.git' \
    -o -path './tests' -o -path './dist' -o -path './build' \
    -o -path './.specify/specs' \
    -o -path './scripts/build-bundle.sh' \
    -o -path './scripts/bundle-allowlist.txt' \
    -o -name 'worktrees' \
    -o -name 'settings.local.json' \
    -o -name 'scheduled_tasks.lock' \
    -o -name '.env' -o -name '.env.*' -o -name '*.env' \
    -o -name '*.pem' -o -name '*.key' -o -name '*.p12' \
    -o -name 'secrets' -o -name 'secrets.*' \
    -o -name '*.log' \
    -o -name '.DS_Store' \
    -o -name 'node_modules' -o -name '__pycache__' -o -name 'coverage' \
  \) -prune -exec rm -rf {} +
)

# --- version stamping -------------------------------------------------------
if [ -f "$BUNDLE/package.json" ]; then
  sed "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" \
    "$BUNDLE/package.json" > "$BUNDLE/package.json.tmp"
  mv "$BUNDLE/package.json.tmp" "$BUNDLE/package.json"
fi

# --- manifest -----------------------------------------------------------------
FILE_COUNT="$(cd "$BUNDLE" && find . -type f | wc -l | tr -d ' ')"
{
  printf '# %s distribution manifest\n' "$PRODUCT"
  printf 'name: %s\n' "$PRODUCT"
  printf 'version: %s\n' "$VERSION"
  printf 'revision: %s\n' "$REVISION"
  printf 'format: tar.gz\n'
  printf 'files: %s\n' "$FILE_COUNT"
  printf '# <sha256>  <path relative to bundle root>\n'
  (
    cd "$BUNDLE"
    find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s  %s\n' "$(sha256_of "$f")" "$f"
    done
  )
} > "$MANIFEST"

# --- tarball + checksum --------------------------------------------------------
tar -C "$WORK" -czf "$TARBALL" "$NAME"
TAR_SHA="$(sha256_of "$TARBALL")"
printf '%s  %s.tar.gz\n' "$TAR_SHA" "$NAME" > "$CHECKSUM"

# --- release-notes input --------------------------------------------------------
if [ -n "$NOTES" ]; then
  cp "$NOTES" "$NOTES_OUT"
else
  cat > "$NOTES_OUT" <<EOF
# $PRODUCT $VERSION

- Source revision: \`$REVISION\`
- Bundle: \`$NAME.tar.gz\`
- SHA-256: \`$TAR_SHA\`
- Files: $FILE_COUNT (see \`$NAME.manifest.txt\`)

## Summary

<!-- TODO: summarize what changed since the previous release -->

## Changes

### Added
-

### Changed
-

### Fixed
-

## Installation

- New project: use the GitHub template, then follow INSTALL.md.
- Existing repository: extract the bundle, then

      ./deploy.sh --preview <path-to-repo>   # preview changes, keep customizations
      ./deploy.sh <path-to-repo>             # deploy

<!-- Input for a future release process. build-bundle.sh never publishes. -->
EOF
fi

printf 'bundle:    %s\n' "$TARBALL"
printf 'manifest:  %s\n' "$MANIFEST"
printf 'checksum:  %s\n' "$CHECKSUM"
printf 'notes:     %s\n' "$NOTES_OUT"
printf 'not published (build only; creating releases is out of scope)\n'
