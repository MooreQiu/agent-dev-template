#!/usr/bin/env bash
# Acceptance tests for issue #44: persist versioned planning and convergence
# artifacts across workflow runs.
#
# Covers (issue #44 acceptance criteria):
#   AC1 one authoritative storage and retrieval contract documented for
#       plan.md, tasks.md, findings, completion records, and referenced
#       validation evidence
#   AC2 the minimal handoff: a fresh runner restores the bundle a previous
#       run saved, bound to feature identity, approved spec revision, and
#       the validated target commit
#   AC3 stale, missing, mismatched, and ambiguous artifacts are rejected;
#       approved spec and approval records are preserved unchanged
#   AC4 separate fresh-runner executions, duplicate uploads/retrieval, and
#       revision mismatches are tested; retention and recovery limitations
#       are documented
#
# Run: bash tests/test-spec-artifacts.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-spec-artifacts.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

GH_LOG="$TMP/gh.log"
MOCK_BIN="$TMP/bin"
ARTIFACTS="$TMP/artifacts" # <name>.tsv index files and <id>.zip bundles
mkdir -p "$MOCK_BIN" "$ARTIFACTS"

failures=0
ok()   { echo "ok - $1"; }
bad()  { echo "FAIL - $1"; failures=$((failures + 1)); }

check() { # check <description> <command...>
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

digest() { # digest <file> -> sha256 hex (portable macOS/Linux)
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

artifact_path_entries() { # artifact_path_entries <workflow> -> path block entries
  awk '
    /^ *path: \|/ { inp=1; indent=index($0, "path:") - 1; next }
    inp {
      if ($0 ~ /^ *$/) next
      stripped=$0
      sub(/^ +/, "", stripped)
      if (length($0) - length(stripped) <= indent) exit
      print stripped
    }
  ' "$1"
}

# --- mocked gh (records calls; serves artifact list/download from fixtures) ---
cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
if [ "$1" = repo ] && [ "$2" = view ]; then echo "acme/fixture"; exit 0; fi
if [ "$1" = api ]; then
  case "$2" in
    *"/actions/artifacts?"*)
      name=$(printf '%s\n' "$2" | sed -n 's/^.*?name=\([^&]*\)&.*$/\1/p')
      idx="$ARTIFACTS/$name.tsv"
      [ -f "$idx" ] || exit 0
      awk -F'\t' '$3 != "true" { print $2 "\t" $1 }' "$idx" | sort -r | head -n 1 \
        | awk -F'\t' '{print $2 "\t" $1}'
      exit 0
      ;;
    *"/actions/artifacts/"*"/zip")
      id=$(printf '%s\n' "$2" | sed -n 's#^.*/actions/artifacts/\([0-9][0-9]*\)/zip$#\1#p')
      cat "$ARTIFACTS/$id.zip"
      exit 0
      ;;
  esac
  exit 0
fi
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"
export GH_LOG ARTIFACTS

register_artifact() { # register_artifact <id> <created-at> <name> <zip>
  printf '%s\t%s\tfalse\n' "$1" "$2" "$3" >> "$ARTIFACTS/$3.tsv"
  cp "$4" "$ARTIFACTS/$1.zip"
}

register_expired() { # register_expired <id> <created-at> <name>
  printf '%s\t%s\ttrue\n' "$1" "$2" "$3" >> "$ARTIFACTS/$3.tsv"
}

make_bundle() { # make_bundle <zip-out> <staging-root>
  out=$1; root=$2
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  rm -f "$out"
  (cd "$root" && zip -q -r -X "$out" .) 2>/dev/null
}

FEATURE="016-demo"
SPEC_REL="specs/$FEATURE/spec.md"
FD="specs/$FEATURE"
SA="$REPO_ROOT/scripts/spec-artifacts.sh"

# --- fixture repository: approved spec committed, plan/tasks untracked -----
# Mirrors the real flow: the human commits spec.md + approval.json; the
# planning agent writes plan.md/tasks.md which are never committed, only
# uploaded as artifacts. A fresh clone therefore lacks the planning files.
make_repo() { # make_repo <dir>
  fx=$1
  mkdir -p "$fx/scripts" "$fx/specs/$FEATURE"
  cp "$SA" "$fx/scripts/spec-artifacts.sh" 2>/dev/null
  git -C "$fx" -c init.defaultBranch=main init -q
  git -C "$fx" -c user.name=Test -c user.email=test@example.com \
    commit -q --allow-empty -m "init"
  cat > "$fx/$SPEC_REL" <<EOSPEC
# Spec: $FEATURE

## Requirements
- REQ1 The feature works end to end.
EOSPEC
  git -C "$fx" add scripts "$SPEC_REL"
  git -C "$fx" -c user.name=Test -c user.email=test@example.com commit -qm "spec"
  printf '%s\n' "$(git -C "$fx" rev-parse HEAD)" > "$fx/.approved"
  cat > "$fx/$FD/approval.json" <<EOAPP
{
  "spec": "$SPEC_REL",
  "revision": "$(cat "$fx/.approved")",
  "approved_by": "tester",
  "approved_at": "2026-10-10T00:00:00Z"
}
EOAPP
  printf '# Plan: %s\nFirst approved plan body.\n' "$FEATURE" > "$fx/$FD/plan.md"
  printf '# Tasks: %s\n- [ ] T001 First task\n' "$FEATURE" > "$fx/$FD/tasks.md"
  git -C "$fx" add "$FD/approval.json"
  git -C "$fx" -c user.name=Test -c user.email=test@example.com commit -qm "approval"
}

A="$TMP/repo-a"
make_repo "$A"
R1=$(cat "$A/.approved")

OUT_ERR="$TMP/err.txt"
OUT_FILE="$TMP/out.txt"

run_sa() { # run_sa <workdir> [args...] -> $STATUS / $OUT_FILE / $OUT_ERR
  wd=$1; shift
  : > "$GH_LOG"
  OUT=$(cd "$wd" && PATH="$MOCK_BIN:$PATH" bash scripts/spec-artifacts.sh "$@" 2>"$OUT_ERR")
  STATUS=$?
  printf '%s\n' "$OUT" > "$OUT_FILE"
}

approved_hashes() { # approved_hashes <dir> -> digests of the protected files
  digest "$1/$SPEC_REL"
  digest "$1/$FD/approval.json"
}

# ============================================================================
echo "== AC1: one authoritative storage and retrieval contract =="

DOC="$REPO_ROOT/docs/SPEC_ARTIFACTS.md"
check "the contract document exists" test -f "$DOC"
if [ -f "$DOC" ]; then
  check "contract covers planning artifacts (plan.md, tasks.md)" \
    sh -c 'grep -q "plan.md" "$1" && grep -q "tasks.md" "$1"' sh "$DOC"
  check "contract covers convergence artifacts (findings, evidence, completion)" \
    sh -c 'grep -q "findings.jsonl" "$1" && grep -q "complete.json" "$1" && grep -q "evidence" "$1"' sh "$DOC"
  check "contract names the retrieval keys for both artifact kinds" \
    sh -c 'grep -q "manifest.json" "$1" && grep -q "spec-planning-" "$1" && grep -q "spec-convergence-" "$1"' sh "$DOC"
  check "contract keeps approved spec and approval records in git, never in bundles" \
    sh -c 'grep -q "approval.json" "$1" && grep -qE "绝不进入|never" "$1"' sh "$DOC"
  check "contract documents retention limitations" \
    sh -c 'grep -qi "retention\|保留" "$1" && grep -q "90" "$1"' sh "$DOC"
  check "contract documents recovery limitations" \
    sh -c 'grep -qi "recovery\|恢复" "$1"' sh "$DOC"
  check "contract documents the retrieval key and newest-wins semantics" \
    sh -c 'grep -q "最新\|newest" "$1"' sh "$DOC"
  check "contract documents the exit codes including stale" \
    sh -c 'grep -q "stale" "$1" && grep -q "3" "$1"' sh "$DOC"
fi

check "SPEC_START doc points at the artifact contract" \
  sh -c 'grep -q "docs/SPEC_ARTIFACTS.md" "$1"' sh "$REPO_ROOT/docs/SPEC_START.md"
check "SPEC_CONVERGE doc points at the artifact contract" \
  sh -c 'grep -q "docs/SPEC_ARTIFACTS.md" "$1"' sh "$REPO_ROOT/docs/SPEC_CONVERGE.md"
check "AGENTS.md points at the artifact contract" \
  sh -c 'grep -q "docs/SPEC_ARTIFACTS.md" "$1"' sh "$REPO_ROOT/AGENTS.md"

check "the handoff script exists" test -f "$SA"
if [ -f "$SA" ]; then
  check "script retrieves artifacts via the gh REST API only" \
    sh -c 'grep -q "actions/artifacts" "$1" && ! grep -qi "mcp" "$1"' sh "$SA"
  check "script skips expired artifacts when selecting" \
    sh -c 'grep -q "expired" "$1"' sh "$SA"
fi

# ============================================================================
echo "== AC2: manifest binds payload to feature, revision, target =="

if [ -f "$SA" ]; then
  run_sa "$A" manifest planning "$SPEC_REL" "$R1" \
    "$FD/plan.md" "$FD/tasks.md"
  check "manifest planning succeeds" sh -c '[ "$1" = 0 ]' sh "$STATUS"
  MAN="$A/$FD/manifest.json"
  check "manifest lands in the planning bundle root" test -f "$MAN"
  if [ -f "$MAN" ]; then
    check "manifest records kind, feature and spec" \
      sh -c 'grep -Fq "\"kind\": \"planning\"" "$1" && grep -Fq "\"feature\": \"016-demo\"" "$1" && grep -Fq "\"spec\": \"specs/016-demo/spec.md\"" "$1"' sh "$MAN"
    check "manifest binds the approved revision" \
      sh -c 'grep -Fq "\"revision\": \"$2\"" "$1"' sh "$MAN" "$R1"
    check "manifest binds the spec content (blob of the approved revision)" \
      sh -c 'grep -Fq "\"spec_blob\": \"$(git -C "$3" rev-parse "$2:$4")\"" "$1"' \
      sh "$MAN" "$R1" "$A" "$SPEC_REL"
    check "manifest binds a target commit" \
      sh -c 'grep -Fq "\"target\":" "$1"' sh "$MAN"
    PLAN_H=$(digest "$A/$FD/plan.md")
    TASKS_H=$(digest "$A/$FD/tasks.md")
    check "manifest lists every payload file with its sha256" \
      sh -c 'grep -Fq "{\"path\": \"specs/016-demo/plan.md\", \"sha256\": \"$2\"}" "$1" && grep -Fq "{\"path\": \"specs/016-demo/tasks.md\", \"sha256\": \"$3\"}" "$1"' \
      sh "$MAN" "$PLAN_H" "$TASKS_H"
  fi

  run_sa "$A" manifest planning "$SPEC_REL" "$R1"
  check "manifest without payload files is a usage error" \
    sh -c '[ "$1" = 2 ] && grep -qi "usage\|at least one" "$2"' sh "$STATUS" "$OUT_ERR"

  run_sa "$A" manifest planning "$SPEC_REL" "$R1" "$FD/spec.md"
  check "manifest refuses the approved spec as payload" \
    sh -c '[ "$1" != 0 ] && grep -qi "protected\|never travels" "$2"' sh "$STATUS" "$OUT_ERR"

  run_sa "$A" manifest planning "$SPEC_REL" "$R1" "$FD/approval.json"
  check "manifest refuses the approval record as payload" \
    sh -c '[ "$1" != 0 ] && grep -qi "protected\|never travels" "$2"' sh "$STATUS" "$OUT_ERR"

  run_sa "$A" manifest planning "$SPEC_REL" "$R1" "$FD/plan.md" "$FD/plan.md"
  check "manifest refuses duplicate payload files" \
    sh -c '[ "$1" != 0 ] && grep -qi "duplicate" "$2"' sh "$STATUS" "$OUT_ERR"

  run_sa "$A" manifest planning "$SPEC_REL" "$R1" "docs/other.md"
  check "manifest refuses files outside the bundle root" \
    sh -c '[ "$1" != 0 ] && grep -qi "outside\|root" "$2"' sh "$STATUS" "$OUT_ERR"

  run_sa "$A" manifest planning "$SPEC_REL" "$R1" "$FD/missing.md"
  check "manifest refuses nonexistent payload files" \
    sh -c '[ "$1" != 0 ] && grep -qi "not found" "$2"' sh "$STATUS" "$OUT_ERR"

  run_sa "$A" manifest wrong "$SPEC_REL" "$R1" "$FD/plan.md"
  check "unknown kind is a usage error" sh -c '[ "$1" = 2 ]' sh "$STATUS"

  run_sa "$A" manifest planning "$SPEC_REL" "0000000000000000000000000000000000000000" "$FD/plan.md"
  check "unknown revision fails the manifest gates" \
    sh -c '[ "$1" != 0 ] && grep -qi "revision" "$2"' sh "$STATUS" "$OUT_ERR"
fi

# ============================================================================
echo "== AC2: a fresh runner restores what a previous run saved =="

if [ -f "$SA" ]; then
  STAGE="$TMP/stage"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp "$A/$FD/manifest.json" "$A/$FD/plan.md" "$A/$FD/tasks.md" "$STAGE/"
  make_bundle "$TMP/planning.zip" "$STAGE"
  KEY="spec-planning-$FEATURE-$R1"
  register_artifact 12 "2026-10-10T01:00:00Z" "$KEY" "$TMP/planning.zip"

  FRESH="$TMP/fresh"
  git clone -q "$A" "$FRESH" 2>/dev/null
  check "fresh clone has the approved spec but not the planning files" \
    sh -c 'test -f "$1/specs/016-demo/spec.md" && test -f "$1/specs/016-demo/approval.json" && test ! -f "$1/specs/016-demo/plan.md"' sh "$FRESH"

  BEFORE=$(approved_hashes "$FRESH")
  run_sa "$FRESH" restore planning "$SPEC_REL" "$R1"
  check "fresh runner restores the planning bundle" \
    sh -c '[ "$1" = 0 ]' sh "$STATUS"
  check "restored plan.md matches the saved bytes" \
    cmp -s "$A/$FD/plan.md" "$FRESH/$FD/plan.md"
  check "restored tasks.md matches the saved bytes" \
    cmp -s "$A/$FD/tasks.md" "$FRESH/$FD/tasks.md"
  AFTER=$(approved_hashes "$FRESH")
  check "approved spec and approval record are preserved unchanged" \
    sh -c '[ "$1" = "$2" ]' sh "$BEFORE" "$AFTER"
  check "restoration lists and downloads via the artifact endpoints" \
    sh -c 'grep -q "actions/artifacts?name=" "$1" && grep -q "actions/artifacts/12/zip" "$1"' sh "$GH_LOG"
  check "exactly one bundle download happens" \
    sh -c '[ "$(grep -c "/zip" "$1")" = 1 ]' sh "$GH_LOG"
  check "restore never writes gh issues" \
    sh -c '! grep -q "issue" "$1"' sh "$GH_LOG"

  run_sa "$FRESH" restore planning "$SPEC_REL" "$R1"
  check "repeated retrieval is idempotent" \
    sh -c '[ "$1" = 0 ] && cmp -s "$2/specs/016-demo/plan.md" "$3/specs/016-demo/plan.md"' \
    sh "$STATUS" "$FRESH" "$A"

  run_sa "$FRESH" restore planning "$SPEC_REL" "$R1" --json
  check "restore --json reports the restored paths in one line" \
    sh -c '[ "$(wc -l < "$1" | tr -d " ")" = 1 ] && grep -Fq "\"restored\":[\"specs/016-demo/plan.md\",\"specs/016-demo/tasks.md\"]" "$1"' \
    sh "$OUT_FILE"

  # --- convergence kind binds the validated target commit ------------------
  mkdir -p "$A/$FD/convergence/evidence"
  printf '{"id": "V001", "requirement": "REQ1", "kind": "verified", "summary": "ok", "evidence": "tests pass"}\n' \
    > "$A/$FD/convergence/findings.jsonl"
  printf '{"checks": [{"name": "test", "exit": 0}]}\n' \
    > "$A/$FD/convergence/evidence/gate.json"
  printf '{"feature": "016-demo", "status": "complete"}\n' \
    > "$A/$FD/convergence/complete.json"
  TARGET=$(git -C "$A" rev-parse HEAD)
  run_sa "$A" manifest convergence "$SPEC_REL" "$R1" --target "$TARGET" \
    "$FD/convergence/findings.jsonl" \
    "$FD/convergence/evidence/gate.json" \
    "$FD/convergence/complete.json"
  check "manifest convergence succeeds with an explicit target" \
    sh -c '[ "$1" = 0 ]' sh "$STATUS"
  check "convergence manifest records the validated target commit" \
    sh -c 'grep -Fq "\"target\": \"$2\"" "$1"' \
    sh "$A/$FD/convergence/manifest.json" "$TARGET"

  CSTAGE="$TMP/cstage"
  rm -rf "$CSTAGE"; mkdir -p "$CSTAGE/evidence"
  cp "$A/$FD/convergence/manifest.json" "$A/$FD/convergence/findings.jsonl" \
    "$A/$FD/convergence/complete.json" "$CSTAGE/"
  cp "$A/$FD/convergence/evidence/gate.json" "$CSTAGE/evidence/"
  make_bundle "$TMP/convergence.zip" "$CSTAGE"
  CKEY="spec-convergence-$FEATURE-$R1"
  register_artifact 31 "2026-10-10T02:00:00Z" "$CKEY" "$TMP/convergence.zip"

  CFRESH="$TMP/cfresh"
  git clone -q "$A" "$CFRESH" 2>/dev/null
  run_sa "$CFRESH" restore convergence "$SPEC_REL" "$R1" --target "$TARGET"
  check "matching target restores findings, evidence and completion record" \
    sh -c '[ "$1" = 0 ] && test -f "$2/specs/016-demo/convergence/findings.jsonl" && test -f "$2/specs/016-demo/convergence/evidence/gate.json" && test -f "$2/specs/016-demo/convergence/complete.json"' \
    sh "$STATUS" "$CFRESH"
  check "restored evidence matches the saved bytes" \
    cmp -s "$A/$FD/convergence/evidence/gate.json" "$CFRESH/$FD/convergence/evidence/gate.json"

  run_sa "$CFRESH" restore convergence "$SPEC_REL" "$R1" --target "$R1"
  check "moved target makes the bundle stale, never silently reused" \
    sh -c '[ "$1" = 4 ] && grep -qi "stale" "$2"' sh "$STATUS" "$OUT_ERR"
fi

# ============================================================================
echo "== AC3: missing, mismatched, ambiguous bundles are rejected =="

if [ -f "$SA" ]; then
  # A sibling commit that also contains the spec: a different valid revision
  # that must never match the first approval's retrieval key.
  printf 'readme\n' > "$A/README.md"
  git -C "$A" add README.md
  git -C "$A" -c user.name=Test -c user.email=test@example.com commit -qm "readme"
  SIB=$(git -C "$A" rev-parse HEAD)

  FRESH2="$TMP/fresh2"
  git clone -q "$A" "$FRESH2" 2>/dev/null
  rm -f "$FRESH2/$FD/plan.md" "$FRESH2/$FD/tasks.md" 2>/dev/null

  run_sa "$FRESH2" restore planning "$SPEC_REL" "$SIB"
  check "retrieval key includes the revision: sibling approvals never match" \
    sh -c '[ "$1" = 3 ] && grep -q "name=spec-planning-016-demo-$SIB" "$2"' \
    sh "$STATUS" "$GH_LOG"

  rm -f "$ARTIFACTS/$KEY.tsv" "$ARTIFACTS/12.zip"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "no artifact at all is reported as not found (exit 3)" \
    sh -c '[ "$1" = 3 ] && grep -qi "no artifact" "$2"' sh "$STATUS" "$OUT_ERR"

  register_expired 13 "2026-10-10T01:10:00Z" "$KEY"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "expired artifacts count as not found" \
    sh -c '[ "$1" = 3 ]' sh "$STATUS"
  rm -f "$ARTIFACTS/$KEY.tsv"

  # helper: rebuild a planning bundle from repo A with a tampered manifest
  tampered_bundle() { # tampered_bundle <id> <sed-script for the manifest>
    T="$TMP/tamper"
    rm -rf "$T"; mkdir -p "$T"
    sed "$2" "$A/$FD/manifest.json" > "$T/manifest.json"
    cp "$A/$FD/tasks.md" "$T/"
    cp "$TMP/stage/plan.md" "$T/"
    make_bundle "$TMP/tampered.zip" "$T"
    rm -f "$ARTIFACTS/$KEY.tsv"
    register_artifact "$1" "2026-10-10T03:00:00Z" "$KEY" "$TMP/tampered.zip"
  }

  tampered_bundle 41 "s/\"revision\": \"$R1\"/\"revision\": \"$SIB\"/"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "revision mismatch inside the manifest is rejected" \
    sh -c '[ "$1" = 1 ] && grep -qi "revision" "$2"' sh "$STATUS" "$OUT_ERR"

  tampered_bundle 42 "s/\"feature\": \"016-demo\"/\"feature\": \"017-other\"/"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "feature mismatch is rejected" \
    sh -c '[ "$1" = 1 ] && grep -qi "feature" "$2"' sh "$STATUS" "$OUT_ERR"

  tampered_bundle 43 "s/\"spec_blob\": \"[0-9a-f]*\"/\"spec_blob\": \"0000000000000000000000000000000000000000\"/"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "spec content binding mismatch is rejected" \
    sh -c '[ "$1" = 1 ] && grep -qi "spec" "$2"' sh "$STATUS" "$OUT_ERR"

  # corrupt payload: hash recorded in the manifest no longer matches
  T="$TMP/hash"
  rm -rf "$T"; mkdir -p "$T"
  cp "$A/$FD/manifest.json" "$T/"
  cp "$A/$FD/tasks.md" "$T/"
  printf 'tampered after manifest was written\n' > "$T/plan.md"
  make_bundle "$TMP/hash.zip" "$T"
  rm -f "$ARTIFACTS/$KEY.tsv"
  register_artifact 44 "2026-10-10T03:00:00Z" "$KEY" "$TMP/hash.zip"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "hash mismatch is rejected as corrupt" \
    sh -c '[ "$1" = 1 ] && grep -qi "hash\|corrupt" "$2"' sh "$STATUS" "$OUT_ERR"
  check "a rejected bundle leaves nothing behind" \
    test ! -f "$FRESH2/$FD/plan.md"

  # missing listed file in the bundle
  T="$TMP/miss"
  rm -rf "$T"; mkdir -p "$T"
  cp "$A/$FD/manifest.json" "$T/"
  cp "$TMP/stage/plan.md" "$T/"
  make_bundle "$TMP/miss.zip" "$T"
  rm -f "$ARTIFACTS/$KEY.tsv"
  register_artifact 45 "2026-10-10T03:00:00Z" "$KEY" "$TMP/miss.zip"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "bundle missing a listed file is rejected" \
    sh -c '[ "$1" = 1 ] && grep -qi "missing" "$2"' sh "$STATUS" "$OUT_ERR"

  # unlisted extra file inside the bundle
  T="$TMP/extra"
  rm -rf "$T"; mkdir -p "$T"
  cp "$A/$FD/manifest.json" "$T/"
  cp "$A/$FD/tasks.md" "$T/"
  cp "$TMP/stage/plan.md" "$T/"
  printf 'not in the manifest\n' > "$T/smuggled.txt"
  make_bundle "$TMP/extra.zip" "$T"
  rm -f "$ARTIFACTS/$KEY.tsv"
  register_artifact 46 "2026-10-10T03:00:00Z" "$KEY" "$TMP/extra.zip"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "unlisted bundle content is rejected as ambiguous" \
    sh -c '[ "$1" = 1 ] && grep -qi "ambiguous\|unlisted\|match" "$2"' sh "$STATUS" "$OUT_ERR"

  # duplicate path entries in the manifest
  T="$TMP/dup"
  rm -rf "$T"; mkdir -p "$T"
  awk '{print} /plan.md/ && !d { print; d=1 }' "$A/$FD/manifest.json" > "$T/manifest.json"
  cp "$A/$FD/tasks.md" "$T/"
  cp "$TMP/stage/plan.md" "$T/"
  make_bundle "$TMP/dup.zip" "$T"
  rm -f "$ARTIFACTS/$KEY.tsv"
  register_artifact 47 "2026-10-10T03:00:00Z" "$KEY" "$TMP/dup.zip"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "duplicate manifest entries are rejected as ambiguous" \
    sh -c '[ "$1" = 1 ] && grep -qi "ambiguous\|duplicate" "$2"' sh "$STATUS" "$OUT_ERR"

  # bundle without a manifest
  T="$TMP/nomani"
  rm -rf "$T"; mkdir -p "$T"
  cp "$A/$FD/tasks.md" "$T/"
  cp "$TMP/stage/plan.md" "$T/"
  make_bundle "$TMP/nomani.zip" "$T"
  rm -f "$ARTIFACTS/$KEY.tsv"
  register_artifact 48 "2026-10-10T03:00:00Z" "$KEY" "$TMP/nomani.zip"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "bundle without manifest.json is rejected" \
    sh -c '[ "$1" = 1 ] && grep -qi "manifest" "$2"' sh "$STATUS" "$OUT_ERR"

  # manifest listing no files
  T="$TMP/empty"
  rm -rf "$T"; mkdir -p "$T"
  sed '/{"path"/d' "$A/$FD/manifest.json" > "$T/manifest.json"
  cp "$A/$FD/tasks.md" "$T/"
  cp "$TMP/stage/plan.md" "$T/"
  make_bundle "$TMP/empty.zip" "$T"
  rm -f "$ARTIFACTS/$KEY.tsv"
  register_artifact 49 "2026-10-10T03:00:00Z" "$KEY" "$TMP/empty.zip"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "manifest without file entries is rejected" \
    sh -c '[ "$1" = 1 ] && grep -qi "no files\|nothing to restore" "$2"' sh "$STATUS" "$OUT_ERR"

  # manifest trying to restore the approved spec (protected path)
  T="$TMP/protect"
  rm -rf "$T"; mkdir -p "$T"
  sed 's#{"path": "specs/016-demo/tasks.md", "sha256": "[0-9a-f]*"}#{"path": "specs/016-demo/spec.md", "sha256": "'"$(digest "$A/$SPEC_REL")"'"}#' \
    "$A/$FD/manifest.json" > "$T/manifest.json"
  cp "$A/$FD/tasks.md" "$T/"
  cp "$TMP/stage/plan.md" "$T/"
  cp "$A/$SPEC_REL" "$T/spec.md"
  make_bundle "$TMP/protect.zip" "$T"
  rm -f "$ARTIFACTS/$KEY.tsv"
  register_artifact 50 "2026-10-10T03:00:00Z" "$KEY" "$TMP/protect.zip"
  BEFORE=$(approved_hashes "$FRESH2")
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "protected paths in the manifest are rejected" \
    sh -c '[ "$1" = 1 ] && grep -qi "protected" "$2"' sh "$STATUS" "$OUT_ERR"
  AFTER2=$(approved_hashes "$FRESH2")
  check "the protected files were never touched" \
    sh -c '[ "$1" = "$2" ]' sh "$BEFORE" "$AFTER2"

  # path trying to escape the bundle root
  T="$TMP/escape"
  rm -rf "$T"; mkdir -p "$T"
  sed 's#specs/016-demo/tasks.md#specs/016-demo/../../evil.md#' \
    "$A/$FD/manifest.json" > "$T/manifest.json"
  cp "$A/$FD/tasks.md" "$T/"
  cp "$TMP/stage/plan.md" "$T/"
  make_bundle "$TMP/escape.zip" "$T"
  rm -f "$ARTIFACTS/$KEY.tsv"
  register_artifact 51 "2026-10-10T03:00:00Z" "$KEY" "$TMP/escape.zip"
  run_sa "$FRESH2" restore planning "$SPEC_REL" "$R1"
  check "paths escaping the bundle root are rejected" \
    sh -c '[ "$1" = 1 ]' sh "$STATUS"
fi

# ============================================================================
echo "== recovery: findings that fail the schema are never restored =="

# Regression for the PR #68 audit verdict: a convergence bundle whose
# findings.jsonl the converge entrypoint would reject (a malformed line, or a
# verified line citing a requirement absent from the approved spec) is
# binding- and hash-valid, so restore used to accept it; every later run then
# skipped evaluation, re-failed on verify, and re-uploaded the same poison --
# a loop no rerun could escape. The next run must re-evaluate, never restore.
if [ -f "$SA" ]; then
  poison_bundle() { # poison_bundle <id> <poisoned-findings-file>
    P="$TMP/poison"
    rm -rf "$P"; mkdir -p "$P/evidence"
    cp "$2" "$P/findings.jsonl"
    cp "$A/$FD/convergence/complete.json" "$P/"
    cp "$A/$FD/convergence/evidence/gate.json" "$P/evidence/"
    # The workflow binds first and hashes what it binds: rebuild that shape
    # around the poisoned bytes so only the content is wrong.
    sed 's#{"path": "specs/016-demo/convergence/findings.jsonl", "sha256": "[0-9a-fA-F]*"}#{"path": "specs/016-demo/convergence/findings.jsonl", "sha256": "'"$(digest "$P/findings.jsonl")"'"}#' \
      "$A/$FD/convergence/manifest.json" > "$P/manifest.json"
    make_bundle "$TMP/poison.zip" "$P"
    rm -f "$ARTIFACTS/$CKEY.tsv"
    register_artifact "$1" "2026-10-10T06:00:00Z" "$CKEY" "$TMP/poison.zip"
  }

  PF="$TMP/poison-findings.jsonl"
  PFRESH="$TMP/poison-fresh"
  git clone -q "$A" "$PFRESH" 2>/dev/null

  # flavor 1: agent prose leaked into the JSON Lines file
  {
    printf '{"id": "G001", "requirement": "REQ1", "kind": "missing", "summary": "gap", "evidence": "tests/demo.txt"}\n'
    printf 'The convergence looks mostly complete to me.\n'
  } > "$PF"
  poison_bundle 81 "$PF"
  run_sa "$PFRESH" restore convergence "$SPEC_REL" "$R1" --target "$TARGET"
  check "a binding-valid bundle with malformed findings is not restored" \
    sh -c '[ "$1" = 5 ] && grep -qi "findings" "$2"' sh "$STATUS" "$OUT_ERR"
  check "malformed findings never reach the checkout" \
    test ! -f "$PFRESH/$FD/convergence/findings.jsonl"

  # flavor 2: a verified line citing a requirement the approved spec lacks
  {
    printf '{"id": "G001", "requirement": "REQ1", "kind": "missing", "summary": "gap", "evidence": "tests/demo.txt"}\n'
    printf '{"id": "V999", "requirement": "REQ999", "kind": "verified", "summary": "ok", "evidence": "trust me"}\n'
  } > "$PF"
  poison_bundle 82 "$PF"
  run_sa "$PFRESH" restore convergence "$SPEC_REL" "$R1" --target "$TARGET"
  check "a verified finding citing an unknown requirement is not restored" \
    sh -c '[ "$1" = 5 ] && grep -qi "requirement" "$2"' sh "$STATUS" "$OUT_ERR"

  # The stored poison must not survive as "the" convergence state: the
  # workflow maps this rejection to the same path as stale -- evaluation.
  check "schema-invalid bundles send the next run to fresh evaluation" \
    sh -c 'grep -A16 "spec-artifacts.sh restore convergence" "$1" | grep -q "5)"' \
    sh "$REPO_ROOT/.github/workflows/spec-converge.yml"
fi

# ============================================================================
echo "== AC4: duplicate uploads and newest-wins retrieval =="

if [ -f "$SA" ]; then
  rm -f "$ARTIFACTS/$KEY.tsv"
  rm -f "$ARTIFACTS"/*.zip

  # upload v1 (older), then v2 (newer) for the same key
  printf '# Plan: %s\nFirst approved plan body.\n' "$FEATURE" > "$A/$FD/plan.md"
  run_sa "$A" manifest planning "$SPEC_REL" "$R1" "$FD/plan.md" "$FD/tasks.md"
  T="$TMP/v1"; rm -rf "$T"; mkdir -p "$T"
  cp "$A/$FD/manifest.json" "$A/$FD/plan.md" "$A/$FD/tasks.md" "$T/"
  make_bundle "$TMP/v1.zip" "$T"

  printf '# Plan: %s\nRevised planning after a rerun.\n' "$FEATURE" > "$A/$FD/plan.md"
  run_sa "$A" manifest planning "$SPEC_REL" "$R1" "$FD/plan.md" "$FD/tasks.md"
  T="$TMP/v2"; rm -rf "$T"; mkdir -p "$T"
  cp "$A/$FD/manifest.json" "$A/$FD/plan.md" "$A/$FD/tasks.md" "$T/"
  make_bundle "$TMP/v2.zip" "$T"

  register_artifact 61 "2026-10-10T04:00:00Z" "$KEY" "$TMP/v1.zip"
  register_artifact 62 "2026-10-10T04:30:00Z" "$KEY" "$TMP/v2.zip"

  DUP="$TMP/dup-fresh"
  git clone -q "$A" "$DUP" 2>/dev/null
  run_sa "$DUP" restore planning "$SPEC_REL" "$R1"
  check "duplicate uploads resolve to the newest bundle" \
    sh -c '[ "$1" = 0 ] && grep -Fq "Revised planning after a rerun." "$2"' \
    sh "$STATUS" "$DUP/$FD/plan.md"
  check "only the newest artifact id is downloaded" \
    sh -c 'grep -q "actions/artifacts/62/zip" "$1" && ! grep -q "actions/artifacts/61/zip" "$1"' sh "$GH_LOG"

  rm -f "$ARTIFACTS/$KEY.tsv"
  register_artifact 71 "2026-10-10T05:00:00Z" "$KEY" "$TMP/v1.zip"
  register_artifact 72 "2026-10-10T05:00:00Z" "$KEY" "$TMP/v2.zip"
  run_sa "$DUP" restore planning "$SPEC_REL" "$R1"
  check "identical timestamps break ties by artifact id deterministically" \
    sh -c '[ "$1" = 0 ] && grep -q "actions/artifacts/72/zip" "$2"' sh "$STATUS" "$GH_LOG"
fi

# ============================================================================
echo "== wiring: workflows persist and restore via the contract =="

WFS="$REPO_ROOT/.github/workflows/spec-start.yml"
WFC="$REPO_ROOT/.github/workflows/spec-converge.yml"

check "spec-start workflow grants artifact read access" \
  sh -c 'grep -q "actions: read" "$1"' sh "$WFS"
check "spec-converge workflow grants artifact read access" \
  sh -c 'grep -q "actions: read" "$1"' sh "$WFC"

if [ -f "$WFS" ]; then
  check "spec-start restores planning artifacts before validating" \
    sh -c 'r=$(grep -n "spec-artifacts.sh restore planning" "$1" | head -1 | cut -d: -f1); \
           v=$(grep -n "Validate the approved spec" "$1" | head -1 | cut -d: -f1); \
           [ -n "$r" ] && [ -n "$v" ] && [ "$r" -lt "$v" ]' sh "$WFS"
  check "spec-start maps not-found to fresh planning instead of failing" \
    sh -c 'grep -A14 "spec-artifacts.sh restore planning" "$1" | grep -q "3)"' sh "$WFS"
  check "spec-start fails closed on rejected bundles" \
    sh -c 'grep -A14 "spec-artifacts.sh restore planning" "$1" | grep -q "exit"' sh "$WFS"
  check "spec-start binds the manifest before uploading" \
    sh -c 'm=$(grep -n "spec-artifacts.sh manifest planning" "$1" | head -1 | cut -d: -f1); \
           u=$(grep -n "Upload planning artifacts" "$1" | head -1 | cut -d: -f1); \
           [ -n "$m" ] && [ -n "$u" ] && [ "$m" -lt "$u" ]' sh "$WFS"
  check "planning artifact name binds feature and revision" \
    sh -c 'grep -q "name: spec-planning-" "$1" && grep -q "env.FEATURE" "$1" && grep -q "inputs.revision" "$1"' sh "$WFS"
  ARTIFACT_PATHS="$TMP/start-paths.txt"
  artifact_path_entries "$WFS" > "$ARTIFACT_PATHS"
  check "planning bundle carries manifest, plan and tasks" \
    sh -c 'grep -q "manifest\.json" "$1" && grep -q "plan\.md" "$1" && grep -q "tasks\.md" "$1"' \
    sh "$ARTIFACT_PATHS"
  check "planning bundle never carries the approved spec" \
    sh -c '! grep -q "spec\.md" "$1"' sh "$ARTIFACT_PATHS"
fi

if [ -f "$WFC" ]; then
  check "spec-converge restores only after a ready precheck" \
    sh -c 'grep -B3 "spec-artifacts.sh restore convergence" "$1" | grep -q "steps.precheck.outputs.outcome"' sh "$WFC"
  check "spec-converge binds the restored bundle to the current target" \
    sh -c 'grep -A4 "spec-artifacts.sh restore convergence" "$1" | grep -q "rev-parse HEAD"' sh "$WFC"
  check "fresh evaluation runs when no bundle is reusable" \
    sh -c 'grep -q "steps.restore.outputs.outcome == .evaluate." "$1" && grep -q "scripts/agent.sh" "$1"' sh "$WFC"
  check "restored findings skip the agent evaluation" \
    sh -c 'grep -B2 "scripts/agent.sh" "$1" | grep -q "steps.restore.outputs.outcome"' sh "$WFC"
  check "spec-converge binds the manifest to the validated target" \
    sh -c 'grep -A6 "spec-artifacts.sh manifest convergence" "$1" | grep -q "rev-parse HEAD"' sh "$WFC"
  check "convergence artifact name binds feature and revision" \
    sh -c 'grep -q "name: spec-convergence-" "$1" && grep -q "env.FEATURE" "$1"' sh "$WFC"
  CARTIFACT_PATHS="$TMP/converge-paths.txt"
  artifact_path_entries "$WFC" > "$CARTIFACT_PATHS"
  check "convergence bundle carries the binding manifest" \
    sh -c 'grep -q "manifest\.json" "$1" && grep -q "findings.jsonl" "$1" && grep -q "evidence" "$1"' \
    sh "$CARTIFACT_PATHS"
  # Persistence gating (PR #68 audit verdict): bind/upload must never run on
  # a bare always-plus-ready condition -- findings the verify step did not
  # validate must never be bound into a "valid" bundle and uploaded.
  check "spec-converge verify step exposes a validation status output" \
    sh -c 'grep -q "id: verify" "$1"' sh "$WFC"
  check "convergence bind persists only findings the verify step validated" \
    sh -c 'grep -A2 "name: Bind the convergence bundle manifest" "$1" | grep -q "steps.verify.outputs.status"' sh "$WFC"
  check "convergence upload persists only findings the verify step validated" \
    sh -c 'grep -A2 "name: Upload convergence artifacts" "$1" | grep -q "steps.verify.outputs.status"' sh "$WFC"
  check "every persisting step gates on the verify status" \
    sh -c '! grep "always()" "$1" | grep "steps.precheck.outputs.outcome" | grep -v "steps.verify.outputs.status" | grep -q .' sh "$WFC"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
