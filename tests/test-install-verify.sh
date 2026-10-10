#!/usr/bin/env bash
# Acceptance tests for issue #52: verify installation in clean repositories.
# A release candidate must work outside the development checkout and preserve
# existing project files. Exercises the versioned distribution bundle end to
# end against fixture repositories with a mocked gh CLI (no network access):
#   AC1  reproducible installation into a fresh repository and into an
#        existing repository with customized instructions, scripts and
#        workflows
#   AC2  repeated installation, upgrade/rollback within the documented scope,
#        and preservation of user files (preview/conflict behavior is covered
#        by tests/test-deploy-preview.sh)
#   AC3  bundle checksum, required files and configuration verified before
#        executing the installed task pipeline (agent-preflight verify-project)
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-test-install.XXXXXX")"
GH_LOG="$TMP/gh.log"
VERSION="0.52.0"
NAME="agent-dev-template-$VERSION"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

failures=0
check() { # check <description> <command> [args...]
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    failures=$((failures + 1))
  fi
}

check_fails() { # check_fails <description> <command> [args...]: pass on error
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: $desc"
    failures=$((failures + 1))
  else
    echo "PASS: $desc"
  fi
}

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

# --- mocked gh (records every call; never touches the network) ------------
MOCK_BIN="$TMP/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$*" in
  *nameWithOwner*) echo "acme/fixture" ;;
  *defaultBranchRef*) echo "trunk" ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/gh"

# make_fixture <dir>: clean repository on branch trunk with a bare origin
make_fixture() { # <dir>
  rm -rf "$1" "$1.git"
  mkdir -p "$1"
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD refs/heads/trunk
  echo "# user project" > "$1/README.md"
  echo "license text" > "$1/LICENSE"
  mkdir -p "$1/src"
  echo "echo user code" > "$1/src/run.sh"
  git -C "$1" add -A
  git -C "$1" commit -q -m "init"
  git init -q --bare "$1.git"
  git -C "$1" remote add origin "$1.git"
  git -C "$1" push -q origin trunk
}

commit_and_push() { # commit_and_push <fixture-dir> <message>: the installer
  # resolves the target default branch on the origin remote, so any state it
  # must see has to be pushed first
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
  git -C "$1" push -q origin trunk
}

merge_deploy_branch() { # merge_deploy_branch <fixture-dir>: simulate the
  # deploy PR being merged so the target carries every installed component
  git -C "$1" checkout -q trunk
  git -C "$1" merge -q --ff-only chore/agent-dev-template
  git -C "$1" push -q origin trunk
}

run_install() { # run_install <bundle-dir> <fixture-dir> <outfile>
  ( cd "$1" && PATH="$MOCK_BIN:$PATH" ANTHROPIC_AUTH_TOKEN= \
      bash ./deploy.sh "$2" ) > "$3" 2>&1
}

# --- build and extract the distribution bundle from the pinned revision ----
REV="$(git -C "$REPO_ROOT" rev-parse HEAD)"
OUT="$TMP/dist"
if bash "$REPO_ROOT/scripts/build-bundle.sh" --source "$REPO_ROOT" \
     --version "$VERSION" --revision "$REV" --output "$OUT" \
     > "$TMP/build.log" 2>&1; then
  echo "PASS: build-bundle.sh exits 0"
else
  echo "FAIL: build-bundle.sh exits 0"
  head -3 "$TMP/build.log"
  exit 1
fi

TARBALL="$OUT/$NAME.tar.gz"
MANIFEST="$OUT/$NAME.manifest.txt"
CHECKSUM="$OUT/$NAME.sha256"
EXTRACT="$TMP/bundle"
mkdir -p "$EXTRACT"
tar -xzf "$TARBALL" -C "$EXTRACT"
BUNDLE_DIR="$EXTRACT/$NAME"
tar -tzf "$TARBALL" > "$TMP/listing.txt"

# ===========================================================================
echo "== AC3: bundle checksum and required files before installation =="
check "tarball checksum verifies (sha256sum -c)" \
  verify_checksum_file "$OUT" "$NAME.sha256"

# A tampered artifact must fail the recorded checksum in a fresh directory.
TAMPER="$TMP/tamper"
mkdir -p "$TAMPER"
cp "$TARBALL" "$TAMPER/$NAME.tar.gz"
cp "$CHECKSUM" "$TAMPER/$NAME.sha256"
printf 'x' >> "$TAMPER/$NAME.tar.gz"
check_fails "tampered bundle fails the checksum verification" \
  verify_checksum_file "$TAMPER" "$NAME.sha256"

check "manifest records the bundle version" \
  sh -c 'grep -q "^version: $2\$" "$1"' sh "$MANIFEST" "$VERSION"
check "manifest records the source revision" \
  sh -c 'grep -q "^revision: $2\$" "$1"' sh "$MANIFEST" "$REV"

# Runtime-critical files the installed task pipeline needs: instructions,
# guides, dispatcher scripts, agent configuration and the automation that
# reviews and merges agent work.
REQUIRED_IN_BUNDLE='AGENTS.md CLAUDE.md INSTALL.md README.md package.json
package-lock.json deploy.sh setup.sh
docs/OPERATIONS.md docs/RUN_CONTROL.md docs/UPGRADE.md docs/BUNDLE.md
scripts/agent.sh scripts/agent-task.sh scripts/agent-claim.sh
scripts/agent-preflight.sh scripts/ci-gate.sh scripts/review-verdict.sh
scripts/model-config.sh scripts/bootstrap-env.sh
.agent/project.json .agent/roles.json .agent/budgets.json
.claude/commands/claim.md .claude/skills/speckit-plan/SKILL.md
.codex/skills/speckit-plan/SKILL.md
.github/workflows/claude.yml .github/workflows/agent-sweep.yml
.github/workflows/pr-review.yml .github/workflows/review-watchdog.yml
.github/workflows/project-sync.yml
.github/PULL_REQUEST_TEMPLATE.md .github/ISSUE_TEMPLATE/config.yml
.specify/memory/constitution.md .specify/templates/spec-template.md
.specify/scripts/bash/setup-tasks.sh'
for f in $REQUIRED_IN_BUNDLE; do
  check "bundle ships $f" \
    sh -c 'grep -q "^$2/$3\$" "$1"' sh "$TMP/listing.txt" "$NAME" "$f"
done

shipped_hash="$(sha256_of "$BUNDLE_DIR/AGENTS.md")"
listed_hash="$(grep "  AGENTS\.md\$" "$MANIFEST" | cut -d' ' -f1)"
check "manifest per-file sha256 matches the shipped content" \
  test "$shipped_hash" = "$listed_hash"

# ===========================================================================
echo "== AC1: fresh repository installation from the bundle =="
FIX="$TMP/fresh"
make_fixture "$FIX"
run_install "$BUNDLE_DIR" "$FIX" "$TMP/out-fresh.txt"

REQUIRED='AGENTS.md CLAUDE.md INSTALL.md docs/OPERATIONS.md docs/UPGRADE.md
scripts/agent.sh scripts/agent-preflight.sh scripts/ci-gate.sh
.agent/project.json .agent/roles.json package.json package-lock.json
.claude/commands/claim.md .claude/skills/speckit-plan/SKILL.md
.github/workflows/claude.yml .github/workflows/pr-review.yml
.github/workflows/agent-sweep.yml .github/workflows/review-watchdog.yml
.github/workflows/project-sync.yml setup.sh .specify/memory/constitution.md'
for f in $REQUIRED; do
  check "$f deployed to the fresh repository" test -f "$FIX/$f"
  check "$f staged in the deploy commit" \
    git -C "$FIX" ls-files --error-unmatch "$f"
done
check "deploy branch based on the target default branch (trunk)" \
  sh -c 'test "$(git -C "$1" rev-parse chore/agent-dev-template^)" = "$(git -C "$1" rev-parse origin/trunk)"' sh "$FIX"
check "complete deployment reported" \
  sh -c 'grep -q "全部必要组件已部署" "$1"' sh "$TMP/out-fresh.txt"

# ===========================================================================
echo "== AC3: installed configuration gate before the task pipeline =="
check "verify-project passes in the installed repository" \
  sh -c 'cd "$1" && PATH="$2:$PATH" bash scripts/agent-preflight.sh verify-project' \
  sh "$FIX" "$MOCK_BIN"
check "verify-project passes in the extracted bundle" \
  sh -c 'cd "$1" && bash scripts/agent-preflight.sh verify-project' sh "$BUNDLE_DIR"

# The gate must stay fail-closed: an unresolved placeholder in the installed
# configuration blocks the task pipeline.
sed 's/"install": "npm install"/"install": "TODO"/' \
  "$FIX/.agent/project.json" > "$FIX/.agent/project.json.bad"
mv "$FIX/.agent/project.json.bad" "$FIX/.agent/project.json"
check_fails "verify-project rejects placeholder configuration in the installed repo" \
  sh -c 'cd "$1" && PATH="$2:$PATH" bash scripts/agent-preflight.sh verify-project' \
  sh "$FIX" "$MOCK_BIN"

# ===========================================================================
echo "== AC1: existing repository with customized files =="
FIXC="$TMP/custom"
make_fixture "$FIXC"
printf 'my customized instructions\n' > "$FIXC/AGENTS.md"
printf 'my customized claude config\n' > "$FIXC/CLAUDE.md"
mkdir -p "$FIXC/scripts" "$FIXC/.github/workflows"
printf 'my custom tooling\n' > "$FIXC/scripts/team-tool.sh"
printf 'on: push\nmy-custom-job: {}\n' > "$FIXC/.github/workflows/claude.yml"
commit_and_push "$FIXC" "customize"
run_install "$BUNDLE_DIR" "$FIXC" "$TMP/out-custom.txt"

check "customized AGENTS.md preserved byte-for-byte" \
  sh -c 'test "$(cat "$1")" = "my customized instructions"' sh "$FIXC/AGENTS.md"
check "customized CLAUDE.md preserved byte-for-byte" \
  sh -c 'test "$(cat "$1")" = "my customized claude config"' sh "$FIXC/CLAUDE.md"
check "customized scripts preserved byte-for-byte" \
  sh -c 'test "$(cat "$1")" = "my custom tooling"' sh "$FIXC/scripts/team-tool.sh"
check "customized workflow preserved byte-for-byte" \
  sh -c 'grep -q "^on: push\$" "$1" && grep -q "^my-custom-job: {}\$" "$1"' \
  sh "$FIXC/.github/workflows/claude.yml"
for f in AGENTS.md CLAUDE.md scripts .github/workflows/claude.yml; do
  check "skipped component reported: $f" \
    sh -c 'grep -q "已存在，跳过: $2" "$1"' sh "$TMP/out-custom.txt" "$f"
done
check "incomplete deployment reported" \
  sh -c 'grep -q "部署不完整" "$1"' sh "$TMP/out-custom.txt"
check "no false complete-deployment claim" \
  sh -c '! grep -q "全部必要组件已部署" "$1"' sh "$TMP/out-custom.txt"
check "agent configuration shipped to the customized repository too" \
  test -f "$FIXC/.agent/project.json"
check "template workflow added next to the customized one" \
  test -f "$FIXC/.github/workflows/pr-review.yml"
check "user README untouched by installation" \
  sh -c 'test "$(cat "$1")" = "# user project"' sh "$FIXC/README.md"
check "user LICENSE untouched by installation" \
  sh -c 'test "$(cat "$1")" = "license text"' sh "$FIXC/LICENSE"
check "user source tree untouched by installation" \
  sh -c 'test "$(cat "$1")" = "echo user code"' sh "$FIXC/src/run.sh"
check "deploy commit contains no user file" \
  sh -c '! git -C "$1" show --name-only chore/agent-dev-template | grep -qE "^(README|LICENSE|src/)"' \
  sh "$FIXC"

# ===========================================================================
echo "== AC2: repeated installation is idempotent =="
# Simulate the deploy PR being merged: re-run the installer against a target
# that already carries every component -- nothing may change.
merge_deploy_branch "$FIX"
COMMITS_BEFORE="$(git -C "$FIX" rev-list --count origin/trunk)"
run_install "$BUNDLE_DIR" "$FIX" "$TMP/out-repeat.txt"
repeat_rc=$?

check "repeated installation exits 0" test "$repeat_rc" -eq 0
check "repeated installation copies nothing new" \
  sh -c 'grep -q "没有新文件需要提交" "$1"' sh "$TMP/out-repeat.txt"
check "repeated installation adds no commit" \
  sh -c 'test "$(git -C "$1" rev-list --count origin/trunk)" = "$2"' \
  sh "$FIX" "$COMMITS_BEFORE"
check "repeated installation leaves deployed files intact" \
  test -f "$FIX/scripts/agent-preflight.sh"
check "repeated installation still reports every existing component" \
  sh -c 'grep -q "已存在，跳过: AGENTS.md" "$1"' sh "$TMP/out-repeat.txt"

# ===========================================================================
echo "== AC2: upgrade adds new components and keeps customizations =="
# "Old template" = an earlier template generation: it predates two workflow
# components, so neither the files nor their deploy.sh ITEMS entries exist.
# Upgrading = redeploying the current bundle over an installed, merged, then
# customized target (additive semantics, docs/UPGRADE.md).
OLD="$TMP/old-template"
cp -R "$BUNDLE_DIR" "$OLD"
rm -f "$OLD/.github/workflows/review-watchdog.yml" \
  "$OLD/.github/workflows/project-sync.yml"
grep -v -e '\.github/workflows/review-watchdog\.yml' \
  -e '\.github/workflows/project-sync\.yml' \
  "$OLD/deploy.sh" > "$OLD/deploy.sh.new"
mv "$OLD/deploy.sh.new" "$OLD/deploy.sh"

FIXU="$TMP/upgrade"
make_fixture "$FIXU"
run_install "$OLD" "$FIXU" "$TMP/out-upgrade-old.txt"
check "old template deploys completely" \
  sh -c 'grep -q "全部必要组件已部署" "$1"' sh "$TMP/out-upgrade-old.txt"
merge_deploy_branch "$FIXU"
printf 'user customized instructions\n' > "$FIXU/AGENTS.md"
printf 'older run control doc\n' > "$FIXU/docs/RUN_CONTROL.md"
commit_and_push "$FIXU" "customize after install"

run_install "$BUNDLE_DIR" "$FIXU" "$TMP/out-upgrade-new.txt"
for f in .github/workflows/review-watchdog.yml .github/workflows/project-sync.yml; do
  check "upgrade adds newly introduced $f" test -f "$FIXU/$f"
  check "newly introduced $f staged in the upgrade commit" \
    git -C "$FIXU" ls-files --error-unmatch "$f"
done
check "upgrade does not overwrite an existing component" \
  sh -c 'test "$(cat "$1")" = "older run control doc"' sh "$FIXU/docs/RUN_CONTROL.md"
check "upgrade keeps the user customization" \
  sh -c 'test "$(cat "$1")" = "user customized instructions"' sh "$FIXU/AGENTS.md"
check "upgrade reports the preserved customization" \
  sh -c 'grep -q "已存在，跳过: AGENTS.md" "$1"' sh "$TMP/out-upgrade-new.txt"
# Directory components are compared as a whole: a file added inside an
# existing directory is NOT installed automatically -- the skipped-dir report
# is what tells the user to merge it manually (docs/UPGRADE.md).
check "upgrade flags the outdated directory component for manual merging" \
  sh -c 'grep -q "已存在，跳过: docs" "$1"' sh "$TMP/out-upgrade-new.txt"

# ===========================================================================
echo "== AC2: rollback of a local installation =="
FIXR="$TMP/rollback"
make_fixture "$FIXR"
run_install "$BUNDLE_DIR" "$FIXR" "$TMP/out-rollback.txt"
# Documented local-mode rollback (docs/UPGRADE.md): back to the original
# branch, then delete the deploy branch.
git -C "$FIXR" checkout -q trunk
git -C "$FIXR" branch -q -D chore/agent-dev-template
check "rollback restores the original branch" \
  sh -c 'test "$(git -C "$1" rev-parse --abbrev-ref HEAD)" = trunk' sh "$FIXR"
check "rollback restores the original HEAD" \
  sh -c 'test "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse origin/trunk)"' sh "$FIXR"
for f in setup.sh AGENTS.md scripts/agent.sh .agent/project.json .github/workflows/pr-review.yml; do
  check "rollback removes deployed $f" test ! -e "$FIXR/$f"
done
check "rollback leaves the working tree clean" \
  sh -c 'test -z "$(git -C "$1" status --porcelain)"' sh "$FIXR"
check "rollback keeps user files" \
  sh -c 'test "$(cat "$1")" = "# user project"' sh "$FIXR/README.md"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
