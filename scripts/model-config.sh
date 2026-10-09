#!/usr/bin/env bash
# Model and reasoning-effort resolver for @claude dispatch (issue #9).
#
# Resolves the model and effort for a dispatch run from three layers with
# strict precedence:
#   1. valid overrides parsed from the triggering comment
#      ("@claude model=opus effort=high <task>")
#   2. repository configuration (AGENT_MODEL_DEFAULT / AGENT_MODEL_FLASH /
#      AGENT_EFFORT_DEFAULT; the trivial label selects the flash tier)
#   3. documented fallbacks (glm-5.3[1m] / glm-5.3-flash[1m]; effort unset
#      means the CLI default)
#
# Comment overrides:
#   model   alias sonnet|opus -> AGENT_MODEL_DEFAULT tier,
#           alias haiku       -> AGENT_MODEL_FLASH tier,
#           or a concrete model id (strict charset, no shell
#           metacharacters).
#   effort  low|medium|high|xhigh|max (claude CLI --effort levels).
#   Options must be standalone whitespace-delimited tokens ("models=x" and
#   "prefixmodel=x" are ignored). The same key twice with conflicting
#   values is rejected as ambiguous.
#
# The comment body is untrusted input: it is read from a file and parsed by
# the embedded node script below; only values passing strict allowlist
# validation are emitted, so comment text can never reach executable shell
# code. Invalid options are rejected with an actionable message on stderr.
#
# Usage:
#   scripts/model-config.sh [--comment-file PATH] [--trivial 0|1]
#
# Env:
#   AGENT_MODEL_DEFAULT   normal-tier model (repo var)
#   AGENT_MODEL_FLASH     fast-tier model for trivial issues (repo var)
#   AGENT_EFFORT_DEFAULT  default effort; empty means CLI default (repo var)
#   ANTHROPIC_BASE_URL    provider endpoint, reported without credentials
#
# stdout: NAME=VALUE lines for $GITHUB_ENV (validated values only):
#   AGENT_RESOLVED_MODEL, AGENT_RESOLVED_EFFORT (may be empty),
#   ANTHROPIC_DEFAULT_{SONNET,OPUS}_MODEL = resolved model,
#   ANTHROPIC_DEFAULT_HAIKU_MODEL = flash-tier model,
#   AGENT_RUN_SUMMARY = single-line report for logs/acknowledgement.
# stderr: one "model-config:" report line (endpoint, model, effort,
#   sources, effort effectiveness).
# exit:   0 ok, 2 invalid comment option, 3 invalid repository config.

set -u

usage() {
  cat >&2 <<'EOF'
Usage: scripts/model-config.sh [--comment-file PATH] [--trivial 0|1]
Precedence: comment override (model=/effort=) > repository config
(AGENT_MODEL_DEFAULT/AGENT_MODEL_FLASH/AGENT_EFFORT_DEFAULT) > documented
fallback. See README "Model and effort configuration".
EOF
  exit 2
}

comment_file=""
trivial=0
while [ $# -gt 0 ]; do
  case "$1" in
    --comment-file)
      [ $# -ge 2 ] || usage
      comment_file="$2"
      shift 2
      ;;
    --trivial)
      [ $# -ge 2 ] || usage
      case "$2" in 0|1) trivial="$2" ;; *) usage ;; esac
      shift 2
      ;;
    -h|--help) usage ;;
    *) echo "model-config: unknown option: $1" >&2; usage ;;
  esac
done

COMMENT_FILE="$comment_file" TRIVIAL="$trivial" node <<'NODE'
const fs = require("fs");
const env = process.env;
const err = (code, msg) => { console.error("model-config: " + msg); process.exit(code); };

// Reject messages are echoed into a markdown code fence in a workflow
// comment: never repeat a raw untrusted token there. Strip backticks
// (fence breakers) and control characters, and truncate, so attacker
// text cannot escape the fence or flood the comment.
const sanitize = (s) => {
  const t = String(s).replace(/[`\x00-\x1f\x7f]/g, "").slice(0, 40).trim();
  return t || "(filtered)";
};

const FALLBACK_MODEL = "glm-5.3[1m]";
const FALLBACK_FLASH = "glm-5.3-flash[1m]";
const EFFORTS = ["low", "medium", "high", "xhigh", "max"];
// Allowlist charset: alphanumerics plus . _ : / - [ ]. No whitespace,
// quotes, or shell metacharacters can pass, so emitted values are safe to
// interpolate into quoted shell arguments.
const MODEL_RE = /^[A-Za-z0-9][A-Za-z0-9._:/[\]-]{0,99}$/;
const ALIAS_TIER = { sonnet: "default", opus: "default", haiku: "flash" };

const defaultModel = (env.AGENT_MODEL_DEFAULT || "").trim();
const flashModel = (env.AGENT_MODEL_FLASH || "").trim();
const normal = defaultModel || FALLBACK_MODEL;
const flash = flashModel || FALLBACK_FLASH;

// Repository effort config must be valid if present.
const repoEffort = (env.AGENT_EFFORT_DEFAULT || "").trim();
if (repoEffort && !EFFORTS.includes(repoEffort)) {
  err(3, "invalid AGENT_EFFORT_DEFAULT '" + sanitize(repoEffort) + "': expected one of "
    + EFFORTS.join(", ") + " (or empty for the CLI default). "
    + "Fix it with: gh variable set AGENT_EFFORT_DEFAULT -b <value>");
}

// Read the untrusted comment from a file (never from an interpolated
// string). A missing or empty file means "no overrides".
let body = "";
if (env.COMMENT_FILE) {
  try { body = fs.readFileSync(env.COMMENT_FILE, "utf8"); }
  catch (e) { err(2, "cannot read comment file: " + e.message); }
}

// Parse standalone model=/effort= tokens; later duplicates must agree.
const seen = {};
for (const tok of body.split(/\s+/)) {
  const m = /^(model|effort)=(.*)$/.exec(tok);
  if (!m) continue;
  const [, key, val] = m;
  if (Object.prototype.hasOwnProperty.call(seen, key)) {
    if (seen[key] !== val) {
      err(2, "comment sets " + key + "= more than once with conflicting values ('"
        + sanitize(seen[key]) + "' vs '" + sanitize(val) + "'); keep exactly one");
    }
    continue;
  }
  seen[key] = val;
}

let model, modelSource, modelNote = "";
if (Object.prototype.hasOwnProperty.call(seen, "model")) {
  const raw = seen.model;
  if (!raw) {
    err(2, "empty model= value: use an alias (sonnet, opus, haiku) or a concrete model id");
  }
  if (ALIAS_TIER[raw]) {
    model = ALIAS_TIER[raw] === "flash" ? flash : normal;
    modelSource = "comment-override";
    modelNote = " alias '" + raw + "' -> " + (ALIAS_TIER[raw] === "flash" ? "AGENT_MODEL_FLASH" : "AGENT_MODEL_DEFAULT") + " tier";
  } else if (MODEL_RE.test(raw)) {
    model = raw;
    modelSource = "comment-override";
  } else {
    err(2, "invalid model '" + sanitize(raw) + "': use an alias (sonnet, opus, haiku) or a concrete "
      + "model id of alphanumerics and . _ : / - [ ] with no spaces, quotes, or shell "
      + "metacharacters");
  }
} else if (env.TRIVIAL === "1") {
  model = flash;
  modelSource = flashModel ? "repo-config" : "fallback";
  modelNote = " trivial label -> flash tier";
} else {
  model = normal;
  modelSource = defaultModel ? "repo-config" : "fallback";
}

let effort, effortSource;
if (Object.prototype.hasOwnProperty.call(seen, "effort")) {
  if (!EFFORTS.includes(seen.effort)) {
    err(2, "invalid effort '" + sanitize(seen.effort) + "': expected one of " + EFFORTS.join(", "));
  }
  effort = seen.effort;
  effortSource = "comment-override";
} else if (repoEffort) {
  effort = repoEffort;
  effortSource = "repo-config";
} else {
  effort = "";
  effortSource = "cli-default";
}

// Endpoint report: the base URL only, never credentials (the auth token is
// not read here at all). Non-Anthropic endpoints may ignore --effort, so
// effectiveness is reported as unknown rather than claimed.
const base = (env.ANTHROPIC_BASE_URL || "").trim();
const endpoint = base || "https://api.anthropic.com (default)";
let official = !base;
try {
  official = official || new URL(base).hostname === "api.anthropic.com";
} catch (e) { official = false; }
const effectiveness = effort
  ? (official ? "supported" : "provider-dependent (unknown)")
  : "not-requested";

const summary = "endpoint=" + endpoint + " | model=" + model + " (" + modelSource + ")"
  + " | effort=" + (effort || "(cli-default)") + " (" + effortSource + ")";

const emit = (k, v) => console.log(k + "=" + v);
emit("AGENT_RESOLVED_MODEL", model);
emit("AGENT_RESOLVED_EFFORT", effort);
emit("ANTHROPIC_DEFAULT_SONNET_MODEL", model);
emit("ANTHROPIC_DEFAULT_OPUS_MODEL", model);
emit("ANTHROPIC_DEFAULT_HAIKU_MODEL", flash);
emit("AGENT_RUN_SUMMARY", summary);
console.error("model-config: " + summary + modelNote
  + " | effort-effective=" + effectiveness);
NODE
