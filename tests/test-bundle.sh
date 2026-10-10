#!/usr/bin/env bash
# Acceptance tests for issue #51: versioned distribution bundle.
# Covers: allowlist contents, packaging outputs, version/revision metadata,
# checksum verification, secret/excluded-file sentinels, clean extraction.
# Run: bash tests/test-bundle.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER="$REPO_ROOT/scripts/build-bundle.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bundle-test.XXXXXX")"
VERSION="1.2.3"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+ -- $2}"; failures=$((failures + 1)); }

sha256_of() { # sha256_of <file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

verify_checksum_file() { # verify_checksum_file <dir> <checksum-file-name>
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$1" && sha256sum -c "$2" >/dev/null 2>&1)
  else
    (cd "$1" && shasum -a 256 -c "$2" >/dev/null 2>&1)
  fi
}

# ---------------------------------------------------------------------------
# Fixture: a hermetic source repo cloned from HEAD plus local junk that must
# never enter the bundle (untracked secrets/state, and even *tracked* ones to
# prove the deny list works regardless of what is committed).
# ---------------------------------------------------------------------------
FIX="$WORK/source"
OUT="$WORK/out"

make_source_fixture() {
  mkdir -p "$FIX"
  git -C "$REPO_ROOT" archive HEAD | tar -x -C "$FIX"
  git -C "$FIX" init -q
  git -C "$FIX" add -A
  # Tracked sentinels: committed by accident, must still be excluded.
  printf 'TRACKED_FAKE_SECRET=please-exclude\n' > "$FIX/.env.local"
  mkdir -p "$FIX/.specify/specs/fake-feature"
  printf '# development-only spec artifact\n' > "$FIX/.specify/specs/fake-feature/spec.md"
  printf '{"token":"fake-tracked"}\n' > "$FIX/.claude/settings.local.json"
  git -C "$FIX" add -A -f .env.local .specify/specs .claude/settings.local.json
  git -C "$FIX" -c user.name=bundle-test -c user.email=bundle@test.local \
    commit -qm "fixture snapshot"
  # Untracked local junk: present on disk, must never enter the bundle.
  printf 'API_TOKEN=fake-untracked\n' > "$FIX/.env"
  mkdir -p "$FIX/.claude/worktrees/agent-junk"
  printf 'junk\n' > "$FIX/.claude/worktrees/agent-junk/f.sh"
  printf 'locked\n' > "$FIX/.claude/scheduled_tasks.lock"
  printf 'run log\n' > "$FIX/run.log"
  printf 'super-secret\n' > "$FIX/secrets.txt"
  mkdir -p "$FIX/dist"
  printf 'stale\n' > "$FIX/dist/stale-artifact.txt"
}

make_source_fixture || { echo "FAIL: fixture setup"; exit 1; }
FIX_SHA=$(git -C "$FIX" rev-parse HEAD)

echo "== build bundle (version $VERSION, revision $FIX_SHA)"
if bash "$BUILDER" --source "$FIX" --version "$VERSION" --revision "$FIX_SHA" \
     --output "$OUT" >"$WORK/build.log" 2>&1; then
  pass "build-bundle.sh exits 0"
else
  fail "build-bundle.sh exits 0" "$(head -3 "$WORK/build.log")"
fi

NAME="agent-dev-template-$VERSION"
TARBALL="$OUT/$NAME.tar.gz"
MANIFEST="$OUT/$NAME.manifest.txt"
CHECKSUM="$OUT/$NAME.sha256"
NOTES="$OUT/$NAME.release-notes.md"
LISTING="$WORK/listing.txt"
EXTRACT="$WORK/extract"

# --- AC2: packaging outputs ------------------------------------------------
for f in "$TARBALL" "$MANIFEST" "$CHECKSUM" "$NOTES"; do
  if [ -f "$f" ]; then pass "produces $(basename "$f")"; else fail "produces $(basename "$f")"; fi
done

if [ -f "$TARBALL" ]; then
  tar -tzf "$TARBALL" > "$LISTING"
else
  echo "1 test(s) blocked: no tarball produced"
  exit 1
fi

# --- AC1/AC5: archive contents (runtime allowlist) --------------------------
required_in_bundle() {
  grep -q "^$NAME/$1\$" "$LISTING"
}
for f in \
  AGENTS.md CLAUDE.md LICENSE README.md INSTALL.md CONTRIBUTING.md package.json \
  setup.sh deploy.sh scripts/agent.sh scripts/ci-gate.sh scripts/agent-preflight.sh \
  docs/HARNESSES.md docs/AGENT_ROLES.md .gitattributes .gitignore \
  .agent/project.json .agent/roles.json \
  .claude/commands/claim.md .claude/skills/speckit-plan/SKILL.md \
  .codex/skills/speckit-plan/SKILL.md \
  .github/ISSUE_TEMPLATE/config.yml .github/PULL_REQUEST_TEMPLATE.md \
  .github/workflows/claude.yml .github/workflows/agent-sweep.yml \
  .github/workflows/pr-review.yml .github/workflows/ci.yml \
  .specify/memory/constitution.md .specify/scripts/bash/setup-tasks.sh \
  .specify/templates/spec-template.md .specify/workflows/workflow-registry.json
do
  if required_in_bundle "$f"; then pass "bundle contains $f"
  else fail "bundle contains $f"; fi
done

# --- AC3/AC5: excluded sentinels never enter, even when tracked -------------
absent_from_bundle() { # absent_from_bundle <tar-pattern> <label>
  if grep -q "$1" "$LISTING"; then fail "bundle excludes $2"
  else pass "bundle excludes $2"; fi
}
absent_from_bundle "$NAME/\.git\$\|/\.git/" "git internals (.git)"
absent_from_bundle "$NAME/\.env\$" ".env (untracked)"
absent_from_bundle "$NAME/\.env\.local" ".env.local (tracked)"
absent_from_bundle "settings\.local\.json" ".claude/settings.local.json (tracked)"
absent_from_bundle "/worktrees/" ".claude/worktrees"
absent_from_bundle "scheduled_tasks\.lock" ".claude/scheduled_tasks.lock"
absent_from_bundle "\.log\$" "run logs (*.log)"
absent_from_bundle "secrets\.txt" "secrets files"
absent_from_bundle "$NAME/dist\$\|$NAME/dist/" "generated dist/"
absent_from_bundle "$NAME/tests\$\|$NAME/tests/" "development-only tests/"
absent_from_bundle "build-bundle\.sh" "packaging tooling (build-bundle.sh)"
absent_from_bundle "bundle-allowlist\.txt" "packaging allowlist file"
absent_from_bundle "\.specify/specs" "development-only .specify/specs/"

# --- AC5: clean extraction (single top dir, no traversal) -------------------
if ! grep -v "^$NAME/" "$LISTING" | grep -q .; then
  pass "every archive entry is under $NAME/ (clean extraction)"
else
  fail "every archive entry is under $NAME/" \
    "stray entries: $(grep -v "^$NAME/" "$LISTING" | head -3)"
fi
if grep -q "^\.\|^\.\./\|^/" "$LISTING"; then
  fail "no absolute or relative-parent paths"
else
  pass "no absolute or relative-parent paths"
fi

mkdir -p "$EXTRACT"
if tar -xzf "$TARBALL" -C "$EXTRACT" 2>/dev/null; then
  pass "tarball extracts cleanly"
else
  fail "tarball extracts cleanly"
fi
BUNDLE_DIR="$EXTRACT/$NAME"

if [ -e "$BUNDLE_DIR/.git" ]; then fail "extracted bundle has no .git"
else pass "extracted bundle has no .git"; fi
# Secret sentinel contents must not appear anywhere in extracted files.
if grep -r "TRACKED_FAKE_SECRET\|fake-tracked\|fake-untracked\|super-secret\|please-exclude" \
     "$BUNDLE_DIR" >/dev/null 2>&1; then
  fail "no secret sentinel contents leak into the bundle"
else
  pass "no secret sentinel contents leak into the bundle"
fi

# --- AC5: version/revision metadata ------------------------------------------
if [ -f "$MANIFEST" ]; then
  grep -q "^version: $VERSION\$" "$MANIFEST" \
    && pass "manifest records version $VERSION" \
    || fail "manifest records version $VERSION"
  grep -q "^revision: $FIX_SHA\$" "$MANIFEST" \
    && pass "manifest records source revision" \
    || fail "manifest records source revision"
  # Manifest file list must exactly match extracted files.
  listed=$(grep -c '^[0-9a-f]\{64\}  ' "$MANIFEST" || true)
  ondisk=$(find "$BUNDLE_DIR" -type f | wc -l | tr -d ' ')
  if [ "$listed" = "$ondisk" ] && [ "$listed" -gt 0 ]; then
    pass "manifest file count matches bundle ($listed files)"
  else
    fail "manifest file count matches bundle" "manifest=$listed ondisk=$ondisk"
  fi
  # A sampled per-file hash must match the extracted content.
  manifest_hash=$(grep "  AGENTS\.md\$" "$MANIFEST" | cut -d' ' -f1)
  if [ -n "$manifest_hash" ] && [ "$(sha256_of "$BUNDLE_DIR/AGENTS.md")" = "$manifest_hash" ]; then
    pass "manifest per-file sha256 matches content (AGENTS.md)"
  else
    fail "manifest per-file sha256 matches content (AGENTS.md)"
  fi
  # Every path in the manifest must exist in the extracted bundle.
  missing=0
  while IFS= read -r line; do
    p=$(printf '%s\n' "$line" | cut -d' ' -f3-)
    [ -e "$BUNDLE_DIR/$p" ] || missing=$((missing + 1))
  done < <(grep '^[0-9a-f]\{64\}  ' "$MANIFEST")
  if [ "$missing" -eq 0 ]; then pass "all manifest paths exist in bundle"
  else fail "all manifest paths exist in bundle" "$missing missing"; fi
else
  fail "manifest metadata checks" "manifest missing"
fi

# Version stamping inside the bundle.
if grep -q "\"version\": \"$VERSION\"" "$BUNDLE_DIR/package.json" 2>/dev/null; then
  pass "package.json inside bundle stamped with $VERSION"
else
  fail "package.json inside bundle stamped with $VERSION"
fi

# Lockfile stamping (issue #83): the shipped package-lock.json must agree
# with the stamped package.json at both root occurrences.
LOCKFILE="$BUNDLE_DIR/package-lock.json"
if [ -f "$LOCKFILE" ]; then
  pass "bundle ships package-lock.json"
else
  fail "bundle ships package-lock.json"
fi
# Top-level version field (2-space indent in a lockfileVersion 3 lockfile).
if grep -q "^  \"version\": \"$VERSION\"" "$LOCKFILE" 2>/dev/null; then
  pass "lockfile top-level version stamped with $VERSION"
else
  fail "lockfile top-level version stamped with $VERSION"
fi
# Root packages[""] version field (6-space indent).
if grep -q "^      \"version\": \"$VERSION\"" "$LOCKFILE" 2>/dev/null; then
  pass "lockfile packages[\"\"] version stamped with $VERSION"
else
  fail "lockfile packages[\"\"] version stamped with $VERSION"
fi
# Dependency entries are untouched: compared to the source lockfile the only
# changed lines are the two root version fields (2 removed + 2 added).
diff "$FIX/package-lock.json" "$LOCKFILE" >"$WORK/lock.diff" 2>&1
if [ "$(grep -c '^[<>]' "$WORK/lock.diff")" -eq 4 ] \
     && grep -q '^<   "version": "0.0.0"' "$WORK/lock.diff" \
     && grep -q '^<       "version": "0.0.0"' "$WORK/lock.diff" \
     && grep -q '^>   "version": "'"$VERSION"'"' "$WORK/lock.diff" \
     && grep -q '^>       "version": "'"$VERSION"'"' "$WORK/lock.diff"; then
  pass "lockfile diff touches exactly the two root version fields"
else
  fail "lockfile diff touches exactly the two root version fields" \
    "$(head -4 "$WORK/lock.diff")"
fi

# --- AC5: checksum verification ----------------------------------------------
if [ -f "$CHECKSUM" ]; then
  if verify_checksum_file "$OUT" "$(basename "$CHECKSUM")"; then
    pass "sha256 file verifies the tarball"
  else
    fail "sha256 file verifies the tarball"
  fi
  # The recorded digest must be the real digest of the artifact.
  recorded=$(cut -d' ' -f1 "$CHECKSUM")
  if [ "$recorded" = "$(sha256_of "$TARBALL")" ]; then
    pass "checksum file records the true sha256"
  else
    fail "checksum file records the true sha256"
  fi
  # Tampering must be detected.
  printf 'x' >> "$TARBALL"
  if verify_checksum_file "$OUT" "$(basename "$CHECKSUM")"; then
    fail "checksum detects a tampered bundle"
  else
    pass "checksum detects a tampered bundle"
  fi
else
  fail "checksum verification" "sha256 file missing"
fi

# --- AC2: release-notes input -------------------------------------------------
if [ -f "$NOTES" ]; then
  grep -q "$VERSION" "$NOTES" && pass "release notes reference the version" \
    || fail "release notes reference the version"
  grep -q "$FIX_SHA" "$NOTES" && pass "release notes reference the revision" \
    || fail "release notes reference the revision"
else
  fail "release notes input" "file missing"
fi
CUSTOM="$WORK/custom-notes.md"
printf 'Custom body for %s.\n' "$VERSION" > "$CUSTOM"
OUT2="$WORK/out2"
if bash "$BUILDER" --source "$FIX" --version "$VERSION" --revision "$FIX_SHA" \
     --output "$OUT2" --notes "$CUSTOM" >"$WORK/build2.log" 2>&1 \
     && grep -q "Custom body for $VERSION" "$OUT2/$NAME.release-notes.md"; then
  pass "--notes supplies the release-notes body"
else
  fail "--notes supplies the release-notes body" "$(head -3 "$WORK/build2.log")"
fi

# --- AC2: argument validation -------------------------------------------------
if bash "$BUILDER" --source "$FIX" --output "$OUT" >/dev/null 2>&1; then
  fail "build refuses to run without --version"
else
  pass "build refuses to run without --version"
fi
if bash "$BUILDER" --source "$FIX" --version "not-a-version" --revision "$FIX_SHA" \
     --output "$OUT" >/dev/null 2>&1; then
  fail "build rejects a malformed version"
else
  pass "build rejects a malformed version"
fi
if bash "$BUILDER" --source "$FIX" --version "1.2.4" --revision "main" \
     --output "$OUT" >/dev/null 2>&1; then
  fail "build rejects a mutable ref as revision"
else
  pass "build rejects a mutable ref as revision"
fi
if bash "$BUILDER" --source "$FIX" --version "1.2.4" \
     --revision "0000000000000000000000000000000000000000" \
     --output "$OUT" >/dev/null 2>&1; then
  fail "build rejects an unknown revision"
else
  pass "build rejects an unknown revision"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
