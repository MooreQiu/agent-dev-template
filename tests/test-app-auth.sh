#!/usr/bin/env bash
# Acceptance tests for issue #13: GitHub App authentication for agent workflows.
#
# Criteria covered:
#   - installation token generation path (API mocked, no network)
#   - installation id discovery vs explicit APP_INSTALLATION_ID
#   - missing App configuration reported clearly, safe GITHUB_TOKEN fallback
#   - credentials never printed to stdout/stderr (masked only on runners)
#   - JWT signing with a throwaway RSA key
#   - workflows call scripts/app-auth.sh and persist no checkout credentials
#   - setup runbook exists and is linked from README
#
# Run: bash tests/test-app-auth.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTH="$REPO_ROOT/scripts/app-auth.sh"
DOCS="$REPO_ROOT/docs/GITHUB_APP_SETUP.md"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+ -- $2}"; failures=$((failures + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"
export HOME="$TMP/home"           # isolate git config --global writes
export GITHUB_REPOSITORY="MooreQiu/agent-dev-template"

if [ ! -f "$AUTH" ]; then
  fail "scripts/app-auth.sh exists" "file not found"
  echo "$failures test(s) failed"
  exit 1
fi

# shellcheck source=/dev/null
. "$AUTH" # defines functions only; main is guarded

# --- mock the network layer (no real API calls in tests) ---
API_CALLS="$TMP/api_calls"
: >"$API_CALLS"
MOCK_INSTALL_JSON='{"id":424242}'
MOCK_TOKEN_JSON='{"token":"ghs_mock_installation_token","expires_at":"2026-10-09T12:00:00Z"}'
app_api() { # method path jwt -> body on stdout (test mock)
  printf '%s %s\n' "$1" "$2" >>"$API_CALLS"
  case "$2" in
    */installation) printf '%s' "$MOCK_INSTALL_JSON" ;;
    */access_tokens) printf '%s' "$MOCK_TOKEN_JSON" ;;
    *) echo "unexpected api path: $2" >&2; return 1 ;;
  esac
}

# Runs app_auth_main in an isolated subshell. Args: app_id app_key env_file
# github_token installation_id (empty string means "not set").
# GITHUB_ACTIONS is neutralized so assertions hold identically on runners
# (where it is ambient) and on laptops; set RUNNER_MODE=1 to simulate an
# Actions runner for the add-mask assertions.
run_auth() {
  (
    unset GH_TOKEN APP_INSTALLATION_ID GITHUB_ACTIONS
    if [ -n "${RUNNER_MODE:-}" ]; then export GITHUB_ACTIONS=true; fi
    APP_ID="$1" APP_PRIVATE_KEY="$2" GITHUB_ENV="$3"
    export APP_ID APP_PRIVATE_KEY GITHUB_ENV GITHUB_REPOSITORY
    if [ -n "${4:-}" ]; then export GITHUB_TOKEN="$4"; else unset GITHUB_TOKEN; fi
    if [ -n "${5:-}" ]; then export APP_INSTALLATION_ID="$5"; fi
    app_auth_main
  )
}

# Throwaway RSA key so the JWT path is exercised for real.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "$TMP/key.pem" 2>/dev/null
KEY="$(cat "$TMP/key.pem")"

# --- AC: installation token generation path ---
ENVF="$TMP/env1"
: >"$ENVF"
OUT_A=$(run_auth 123456 "$KEY" "$ENVF" "" "" 2>&1)
RC_A=$?
if [ "$RC_A" -eq 0 ]; then
  pass "app auth succeeds with configured App"
else
  fail "app auth succeeds with configured App" "rc=$RC_A out=$OUT_A"
fi
grep -q '^GH_TOKEN=ghs_mock_installation_token$' "$ENVF" \
  && pass "installation token written to GH_TOKEN (GITHUB_ENV)" \
  || fail "installation token written to GH_TOKEN (GITHUB_ENV)" "env file: $(cat "$ENVF" 2>/dev/null)"
grep -q 'GET /repos/MooreQiu/agent-dev-template/installation' "$API_CALLS" \
  && pass "installation id discovered via repository API" \
  || fail "installation id discovered via repository API" "calls: $(cat "$API_CALLS")"
grep -q 'POST /app/installations/424242/access_tokens' "$API_CALLS" \
  && pass "short-lived token minted via access_tokens endpoint" \
  || fail "short-lived token minted via access_tokens endpoint" "calls: $(cat "$API_CALLS")"
HELPER="$(git config --global credential.helper)"
[ "$HELPER" = '!gh auth git-credential' ] \
  && pass "git credential helper wired to gh (token never hits disk)" \
  || fail "git credential helper wired to gh (token never hits disk)" "helper=$HELPER"

# --- AC: explicit APP_INSTALLATION_ID skips discovery ---
: >"$API_CALLS"
ENVF="$TMP/env2"
: >"$ENVF"
run_auth 123456 "$KEY" "$ENVF" "" 777 >/dev/null 2>&1
if grep -q 'POST /app/installations/777/access_tokens' "$API_CALLS" &&
  ! grep -q '/repos/.*/installation' "$API_CALLS"; then
  pass "APP_INSTALLATION_ID override skips discovery"
else
  fail "APP_INSTALLATION_ID override skips discovery" "calls: $(cat "$API_CALLS")"
fi

# --- AC: missing App config reported clearly, safe fallback ---
ENVF="$TMP/env3"
: >"$ENVF"
OUT_FB=$(run_auth "" "" "$ENVF" "ghs_fallback_token" "" 2>&1)
RC_FB=$?
if [ "$RC_FB" -eq 0 ]; then
  pass "missing App config falls back to GITHUB_TOKEN (exit 0)"
else
  fail "missing App config falls back to GITHUB_TOKEN (exit 0)" "rc=$RC_FB out=$OUT_FB"
fi
grep -q '^GH_TOKEN=ghs_fallback_token$' "$ENVF" \
  && pass "fallback exports GITHUB_TOKEN as GH_TOKEN" \
  || fail "fallback exports GITHUB_TOKEN as GH_TOKEN" "env file: $(cat "$ENVF" 2>/dev/null)"
case "$OUT_FB" in
  *GITHUB_APP_SETUP* | *GITHUB_APP_SETUP.md*) pass "fallback message points to setup docs" ;;
  *) fail "fallback message points to setup docs" "out=$OUT_FB" ;;
esac

ENVF="$TMP/env4"
: >"$ENVF"
OUT_ERR=$(run_auth "" "" "$ENVF" "" "" 2>&1)
RC_ERR=$?
if [ "$RC_ERR" -ne 0 ]; then
  pass "no App config and no GITHUB_TOKEN fails loudly"
else
  fail "no App config and no GITHUB_TOKEN fails loudly" "rc=0"
fi
case "$OUT_ERR" in
  *APP_ID*) pass "error names the missing APP_ID/APP_PRIVATE_KEY secrets" ;;
  *) fail "error names the missing APP_ID/APP_PRIVATE_KEY secrets" "out=$OUT_ERR" ;;
esac

OUT_BADKEY=$(run_auth 123456 "not-a-valid-pem" "$TMP/env5" "" "" 2>&1)
RC_BADKEY=$?
if [ "$RC_BADKEY" -ne 0 ] && printf '%s' "$OUT_BADKEY" | grep -Eqi 'jwt|pem'; then
  pass "invalid private key reported with actionable error"
else
  fail "invalid private key reported with actionable error" "rc=$RC_BADKEY out=$OUT_BADKEY"
fi

# --- AC: credentials stay out of logs ---
# OUT_A is captured with GITHUB_ACTIONS neutralized (run_auth pins it), so
# no output channel may carry the token value, ::add-mask:: included.
case "$OUT_A" in
  *ghs_mock_installation_token*)
    fail "token value never printed to stdout/stderr" "leaked in: $OUT_A" ;;
  *)
    pass "token value never printed to stdout/stderr" ;;
esac
OUT_MASK=$(RUNNER_MODE=1 run_auth 123456 "$KEY" "$TMP/env6" "" "" 2>&1)
case "$OUT_MASK" in
  *'::add-mask::'*) pass "token masked via add-mask on Actions runners" ;;
  *) fail "token masked via add-mask on Actions runners" "out=$OUT_MASK" ;;
esac
# the mask workflow command is the only sanctioned appearance of the token
# on runners: strip those lines and nothing token-like may remain
OUT_MASK_STRIPPED=$(printf '%s\n' "$OUT_MASK" | grep -v '^::add-mask::')
case "$OUT_MASK_STRIPPED" in
  *ghs_mock_installation_token*)
    fail "on runners the token appears only in the add-mask command" \
      "leaked in: $OUT_MASK_STRIPPED" ;;
  *)
    pass "on runners the token appears only in the add-mask command" ;;
esac

# --- AC: JWT is a real RS256 JWT ---
JWT=$(app_jwt_sign 999999 "$TMP/key.pem") && RC_JWT=0 || RC_JWT=1
if [ "$RC_JWT" -eq 0 ]; then
  HEADER_B64="${JWT%%.*}"
  REST="${JWT#*.}"
  PAYLOAD_B64="${REST%%.*}"
  SIG_B64="${REST#*.}"
  decode_b64url() { # write the raw decoded bytes (binary-safe, no utf8 pass)
    node -e 'const a=process.argv[1];const b=a.replace(/-/g,"+").replace(/_/g,"/");process.stdout.write(Buffer.from(b,"base64"))' "$1"
  }
  HEADER=$(decode_b64url "$HEADER_B64")
  PAYLOAD=$(decode_b64url "$PAYLOAD_B64")
  case "$HEADER" in
    *RS256*) pass "JWT header declares RS256" ;;
    *) fail "JWT header declares RS256" "header=$HEADER" ;;
  esac
  case "$PAYLOAD" in
    *'"iss":"999999"'*) pass "JWT payload carries the App ID as iss" ;;
    *) fail "JWT payload carries the App ID as iss" "payload=$PAYLOAD" ;;
  esac
  [ -n "$SIG_B64" ] \
    && pass "JWT carries an RSA signature" \
    || fail "JWT carries an RSA signature" "empty signature"
  # RSA signatures are binary and contain NUL bytes, which shell variables
  # cannot hold (bash drops them, corrupting the signature). Verify the
  # signature cryptographically so the signing path stays binary-safe.
  openssl pkey -in "$TMP/key.pem" -pubout -out "$TMP/jwt_pub.pem" 2>/dev/null
  decode_b64url "$SIG_B64" >"$TMP/jwt_sig.bin"
  if printf '%s' "${JWT%.*}" |
    openssl dgst -sha256 -verify "$TMP/jwt_pub.pem" \
      -signature "$TMP/jwt_sig.bin" >/dev/null 2>&1; then
    pass "JWT signature verifies against the signing key (binary-safe)"
  else
    fail "JWT signature verifies against the signing key (binary-safe)" \
      "signature corrupted between openssl and base64"
  fi
  # Bash command substitution silently strips NUL bytes, and ~65% of
  # RSA-2048/SHA-256 signatures contain one, so a broken signing path still
  # passes whenever the single sampled signature happens to be NUL-free.
  # Iterate fresh signatures (payload varied via the app id, since the same
  # payload within the same second would repeat the same signature) until
  # one containing a NUL byte has verified, proving the binary path.
  sig_has_nul() { # <file> -> 0 when the file contains a 0x00 byte
    node -e 'process.exit(require("fs").readFileSync(process.argv[1]).includes(0)?0:1)' "$1"
  }
  nul_sig_verified=0
  bad_sig=""
  i=0
  while [ "$i" -lt 25 ] && [ -z "$bad_sig" ] && [ "$nul_sig_verified" -eq 0 ]; do
    i=$((i + 1))
    JWT_N=$(app_jwt_sign "$((910000 + i))" "$TMP/key.pem") \
      || { bad_sig="app_jwt_sign rc!=0 at iteration $i"; break; }
    decode_b64url "${JWT_N##*.}" >"$TMP/jwt_sig.bin"
    if printf '%s' "${JWT_N%.*}" |
      openssl dgst -sha256 -verify "$TMP/jwt_pub.pem" \
        -signature "$TMP/jwt_sig.bin" >/dev/null 2>&1; then
      if sig_has_nul "$TMP/jwt_sig.bin"; then nul_sig_verified=$i; fi
    else
      bad_sig="iteration $i: signature does not verify (NUL bytes stripped?)"
    fi
  done
  if [ -n "$bad_sig" ]; then
    fail "a NUL-containing JWT signature verifies cryptographically" "$bad_sig"
  elif [ "$nul_sig_verified" -gt 0 ]; then
    pass "a NUL-containing JWT signature verifies cryptographically"
  else
    fail "a NUL-containing JWT signature verifies cryptographically" \
      "no NUL-containing signature sampled in $i iterations"
  fi
else
  fail "JWT header declares RS256" "app_jwt_sign rc=$RC_JWT"
  fail "JWT payload carries the App ID as iss" "app_jwt_sign rc=$RC_JWT"
  fail "JWT carries an RSA signature" "app_jwt_sign rc=$RC_JWT"
  fail "JWT signature verifies against the signing key (binary-safe)" "app_jwt_sign rc=$RC_JWT"
  fail "a NUL-containing JWT signature verifies cryptographically" "app_jwt_sign rc=$RC_JWT"
fi

# --- AC: workflows use the auth layer consistently ---
for wf in claude.yml agent-sweep.yml pr-review.yml; do
  f="$WORKFLOWS_DIR/$wf"
  grep -Fq 'scripts/app-auth.sh' "$f" \
    && pass "$wf resolves auth via scripts/app-auth.sh" \
    || fail "$wf resolves auth via scripts/app-auth.sh" "no reference found"
  checkouts=$(grep -c 'actions/checkout@' "$f")
  persists=$(grep -c 'persist-credentials: false' "$f")
  if [ "$checkouts" -gt 0 ] && [ "$checkouts" -eq "$persists" ]; then
    pass "$wf persists no checkout credentials"
  else
    fail "$wf persists no checkout credentials" \
      "checkouts=$checkouts persist-credentials=false:$persists"
  fi
done

grep -Fq 'endswith("[bot]")' "$WORKFLOWS_DIR/pr-review.yml" \
  && pass "pr-review verdict lookup accepts any bot author (token or App)" \
  || fail "pr-review verdict lookup accepts any bot author (token or App)" \
    "no endswith(\"[bot]\") found"

# --- AC: setup runbook + smoke test documentation ---
[ -f "$DOCS" ] \
  && pass "docs/GITHUB_APP_SETUP.md exists" \
  || fail "docs/GITHUB_APP_SETUP.md exists" "file not found"
if [ -f "$DOCS" ]; then
  grep -q 'APP_PRIVATE_KEY' "$DOCS" \
    && pass "runbook documents APP_ID/APP_PRIVATE_KEY secrets" \
    || fail "runbook documents APP_ID/APP_PRIVATE_KEY secrets"
  grep -Eqi 'smoke|端到端' "$DOCS" \
    && pass "runbook documents the end-to-end smoke test" \
    || fail "runbook documents the end-to-end smoke test"
fi
grep -q 'GITHUB_APP_SETUP' "$REPO_ROOT/README.md" \
  && pass "README links the GitHub App runbook" \
  || fail "README links the GitHub App runbook" "no link found"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
