#!/usr/bin/env bash
# GitHub App authentication for agent workflows (issue #13).
#
# Exchanges APP_ID + APP_PRIVATE_KEY for a short-lived installation token and
# wires it into gh (GH_TOKEN) and git (credential helper), so automated PR
# creation / fix pushes do not hit the approval gates that apply to
# GITHUB_TOKEN-triggered events.
#
# Behavior:
#   - App configured            -> mint installation token, export GH_TOKEN
#                                  and GH_AUTH_IDENTITY=app
#   - App missing + GITHUB_TOKEN-> fall back to GITHUB_TOKEN with a warning
#                                  and GH_AUTH_IDENTITY=github-token
#   - neither                    -> fail with an actionable message
#
# GH_AUTH_IDENTITY (issue #84) lets consumers tell the two token kinds
# apart -- e.g. the review-verdict merge decider only closes linked issues
# itself under the plain GITHUB_TOKEN, because GitHub already auto-closes
# them for merges performed as an App.
#
# Env (workflow secrets or local shell):
#   APP_ID / GITHUB_APP_ID          GitHub App ID
#   APP_PRIVATE_KEY /               PEM private key of the App
#     GITHUB_APP_PRIVATE_KEY
#   APP_INSTALLATION_ID             optional; auto-discovered when unset
#   GITHUB_REPOSITORY               owner/repo (installation discovery)
#   GITHUB_TOKEN                    fallback token
#   GITHUB_ENV                      Actions env file; GH_TOKEN and
#                                   GH_AUTH_IDENTITY are appended to it
#   GH_API_URL                      API base, default https://api.github.com
#
# The token value is never written to stdout/stderr or to disk. On Actions
# runners it is additionally registered with ::add-mask:: so later steps that
# accidentally echo it get it redacted.

app_b64url() { base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }

app_jwt_sign() { # <app_id> <key_file> -> JWT on stdout
  local app_id=$1 key_file=$2 now header payload sig_file sig
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | app_b64url)
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' \
    "$((now - 60))" "$((now + 300))" "$app_id" | app_b64url)
  # sign to a file: RSA signatures are binary and contain NUL bytes, which
  # shell variables cannot hold (bash drops them and corrupts the
  # signature). openssl remains the last command of the pipeline, so its
  # exit status is not masked by the trailing tr (no pipefail when sourced
  # by tests)
  sig_file=$(mktemp "${TMPDIR:-/tmp}/app-jwt-sig.XXXXXX")
  if ! printf '%s' "$header.$payload" |
    openssl dgst -sha256 -sign "$key_file" -out "$sig_file"; then
    rm -f "$sig_file"
    return 1
  fi
  sig=$(app_b64url <"$sig_file")
  rm -f "$sig_file"
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

app_json_get() { # <json> <access expression, literal from this codebase only>
  printf '%s' "$1" | node -e '
    let s = "";
    process.stdin.on("data", (d) => { s += d; });
    process.stdin.on("end", () => {
      try {
        const v = JSON.parse(s)'"$2"';
        if (v === undefined || v === null) process.exit(1);
        process.stdout.write(String(v));
      } catch (e) { process.exit(1); }
    });
  '
}

app_api() { # <method> <path> <jwt> -> response body on stdout
  curl -fsS -X "$1" \
    -H "Authorization: Bearer $3" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GH_API_URL:-https://api.github.com}$2"
}

app_apply() { # <token> <identity: app|github-token>
  export GH_TOKEN="$1"
  export GH_AUTH_IDENTITY="$2"
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'GH_TOKEN=%s\n' "$1" >>"$GITHUB_ENV"
    printf 'GH_AUTH_IDENTITY=%s\n' "$2" >>"$GITHUB_ENV"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      printf '::add-mask::%s\n' "$1"
    fi
  fi
  # gh serves the token to git without it ever being written to a config file
  git config --global credential.helper '!gh auth git-credential'
}

app_auth_main() {
  local app_id="${APP_ID:-${GITHUB_APP_ID:-}}"
  local app_key="${APP_PRIVATE_KEY:-${GITHUB_APP_PRIVATE_KEY:-}}"

  if [ -z "$app_id" ] || [ -z "$app_key" ]; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      echo "app-auth: GitHub App not configured (need APP_ID and APP_PRIVATE_KEY); falling back to GITHUB_TOKEN. Automated PRs may require manual approval until the App is set up. See docs/GITHUB_APP_SETUP.md" >&2
      app_apply "$GITHUB_TOKEN" github-token
      return 0
    fi
    echo "app-auth: no authentication available. Create a GitHub App and set the APP_ID and APP_PRIVATE_KEY secrets (see docs/GITHUB_APP_SETUP.md), or provide GITHUB_TOKEN." >&2
    return 1
  fi

  local key_file jwt
  key_file=$(mktemp "${TMPDIR:-/tmp}/app-auth-key.XXXXXX")
  trap 'rm -f "$key_file"' RETURN
  printf '%s\n' "$app_key" >"$key_file"
  chmod 600 "$key_file"

  if ! jwt=$(app_jwt_sign "$app_id" "$key_file"); then
    echo "app-auth: failed to sign the JWT with APP_PRIVATE_KEY (is it the PEM private key downloaded from the App settings page?)." >&2
    return 1
  fi
  rm -f "$key_file"

  local installation_id="${APP_INSTALLATION_ID:-}"
  if [ -z "$installation_id" ]; then
    local repo="${GITHUB_REPOSITORY:-}"
    if [ -z "$repo" ]; then
      echo "app-auth: APP_INSTALLATION_ID or GITHUB_REPOSITORY is required to find the installation." >&2
      return 1
    fi
    local resp
    if ! resp=$(app_api GET "/repos/$repo/installation" "$jwt"); then
      echo "app-auth: installation lookup failed for $repo (is the App installed on this repository?)." >&2
      return 1
    fi
    installation_id=$(app_json_get "$resp" '.id') || {
      echo "app-auth: could not parse the installation id from the API response." >&2
      return 1
    }
  fi

  local token_resp token expires
  if ! token_resp=$(app_api POST "/app/installations/$installation_id/access_tokens" "$jwt"); then
    echo "app-auth: installation token exchange failed." >&2
    return 1
  fi
  token=$(app_json_get "$token_resp" '.token') || {
    echo "app-auth: could not parse the installation token from the API response." >&2
    return 1
  }
  expires=$(app_json_get "$token_resp" '.expires_at') || expires="unknown"

  app_apply "$token" app
  echo "app-auth: using GitHub App installation token (expires $expires)" >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  app_auth_main
fi
