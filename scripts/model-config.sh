#!/usr/bin/env bash
# Model and reasoning-effort resolver for agent dispatch (issues #9, #23).
#
# Resolves the harness, model, and effort for a dispatch run from three
# layers with strict precedence:
#   1. valid overrides parsed from the triggering comment
#      ("@claude model=opus effort=high <task>" -- same syntax for
#      @codex, @gemini, and @opencode)
#   2. repository configuration (per-harness model vars; the trivial
#      label selects the claude flash tier)
#   3. documented fallbacks (claude: glm-5.3[1m] / glm-5.3-flash[1m];
#      other harnesses: unset means the CLI default)
#
# Per-harness resolution (issue #23) reuses the same parser, precedence,
# and validation for every harness -- only the knobs differ:
#   claude   AGENT_MODEL_DEFAULT / AGENT_MODEL_FLASH tiers, aliases
#            sonnet|opus -> default tier, haiku -> flash tier;
#            effort low|medium|high|xhigh|max via --effort
#   codex    AGENT_MODEL_CODEX (concrete ids; claude aliases rejected);
#            effort low|medium|high via model_reasoning_effort
#   gemini   AGENT_MODEL_GEMINI; no effort support (overrides rejected,
#            repo default noted as ignored)
#   opencode AGENT_MODEL_OPENCODE (provider/model ids); no effort support
#
# Comment overrides:
#   model   alias sonnet|opus -> AGENT_MODEL_DEFAULT tier,
#           alias haiku       -> AGENT_MODEL_FLASH tier,
#           or a concrete model id (strict charset, no shell
#           metacharacters). Aliases apply to claude only.
#   effort  per-harness enum (see above). Options must be standalone
#           whitespace-delimited tokens ("models=x" and "prefixmodel=x"
#           are ignored). The same key twice with conflicting values is
#           rejected as ambiguous.
#
# The comment body is untrusted input: it is read from a file and parsed by
# the embedded node script below; only values passing strict allowlist
# validation are emitted, so comment text can never reach executable shell
# code. Invalid options are rejected with an actionable message on stderr.
#
# Usage:
#   scripts/model-config.sh [--comment-file PATH] [--trivial 0|1]
#                           [--harness claude|codex|gemini|opencode]
#
# Env:
#   AGENT_MODEL_DEFAULT   claude normal-tier model (repo var)
#   AGENT_MODEL_FLASH     claude fast-tier model for trivial issues (repo var)
#   AGENT_MODEL_CODEX     codex model; empty = CLI default (repo var)
#   AGENT_MODEL_GEMINI    gemini model; empty = CLI default (repo var)
#   AGENT_MODEL_OPENCODE  opencode provider/model; empty = CLI default (repo var)
#   AGENT_EFFORT_DEFAULT  default effort; empty means CLI default (repo var)
#   ANTHROPIC_BASE_URL    claude provider endpoint, reported without credentials
#
# stdout: NAME=VALUE lines for $GITHUB_ENV (validated values only):
#   AGENT_RESOLVED_HARNESS, AGENT_RESOLVED_MODEL (may be empty = CLI
#   default), AGENT_RESOLVED_EFFORT (may be empty),
#   ANTHROPIC_DEFAULT_{SONNET,OPUS}_MODEL = resolved model (claude only),
#   ANTHROPIC_DEFAULT_HAIKU_MODEL = flash-tier model (claude only),
#   AGENT_RUN_SUMMARY = single-line report for logs/acknowledgement.
# stderr: one "model-config:" report line (harness, endpoint for claude,
#   model, effort, sources, effort effectiveness).
# exit:   0 ok, 2 invalid comment option, 3 invalid repository config.

set -u

usage() {
  cat >&2 <<'EOF'
Usage: scripts/model-config.sh [--comment-file PATH] [--trivial 0|1]
                               [--harness claude|codex|gemini|opencode]
Precedence: comment override (model=/effort=) > repository config
(per-harness AGENT_MODEL_* vars) > documented fallback. See README
"Model and effort configuration".
EOF
  exit 2
}

comment_file=""
trivial=0
harness="claude"
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
    --harness)
      [ $# -ge 2 ] || usage
      harness="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) echo "model-config: unknown option: $1" >&2; usage ;;
  esac
done

COMMENT_FILE="$comment_file" TRIVIAL="$trivial" HARNESS="$harness" node <<'NODE'
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

const HARNESSES = ["claude", "codex", "gemini", "opencode"];
const HARNESS = env.HARNESS || "claude";
if (!HARNESSES.includes(HARNESS)) {
  err(2, "unknown harness '" + sanitize(HARNESS) + "': expected one of " + HARNESSES.join(", "));
}

const FALLBACK_MODEL = "glm-5.3[1m]";
const FALLBACK_FLASH = "glm-5.3-flash[1m]";
// Effort enums validated against the supported CLI versions:
// claude --effort and codex model_reasoning_effort (minimal/xhigh are
// version-dependent, so only the stable common set is wired); gemini and
// opencode CLIs have no effort flag in their non-interactive modes.
const EFFORTS_BY_HARNESS = {
  claude: ["low", "medium", "high", "xhigh", "max"],
  codex: ["low", "medium", "high"],
  gemini: [],
  opencode: [],
};
const EFFORTS = EFFORTS_BY_HARNESS[HARNESS];
const EFFORT_HARNESSES = HARNESSES.filter((h) => EFFORTS_BY_HARNESS[h].length > 0);
// Allowlist charset: alphanumerics plus . _ : / - [ ]. No whitespace,
// quotes, or shell metacharacters can pass, so emitted values are safe to
// interpolate into quoted shell arguments.
const MODEL_RE = /^[A-Za-z0-9][A-Za-z0-9._:/[\]-]{0,99}$/;
const ALIAS_TIER = { sonnet: "default", opus: "default", haiku: "flash" };
const MODEL_VAR = {
  codex: "AGENT_MODEL_CODEX",
  gemini: "AGENT_MODEL_GEMINI",
  opencode: "AGENT_MODEL_OPENCODE",
};

const defaultModel = (env.AGENT_MODEL_DEFAULT || "").trim();
const flashModel = (env.AGENT_MODEL_FLASH || "").trim();
const normal = defaultModel || FALLBACK_MODEL;
const flash = flashModel || FALLBACK_FLASH;

// Repository effort config must be valid for the resolved harness when
// the harness supports effort at all.
const repoEffort = (env.AGENT_EFFORT_DEFAULT || "").trim();
if (repoEffort && EFFORTS.length > 0 && !EFFORTS.includes(repoEffort)) {
  err(3, "invalid AGENT_EFFORT_DEFAULT '" + sanitize(repoEffort) + "' for harness " + HARNESS
    + ": expected one of " + EFFORTS.join(", ") + " (or empty for the CLI default). "
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
    if (HARNESS !== "claude") {
      err(2, "model alias '" + sanitize(raw) + "' is claude-specific; harness " + HARNESS
        + " needs a concrete model id (alphanumerics and . _ : / - [ ]) or repository var "
        + MODEL_VAR[HARNESS]);
    }
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
} else if (HARNESS === "claude") {
  if (env.TRIVIAL === "1") {
    model = flash;
    modelSource = flashModel ? "repo-config" : "fallback";
    modelNote = " trivial label -> flash tier";
  } else {
    model = normal;
    modelSource = defaultModel ? "repo-config" : "fallback";
  }
} else {
  const varModel = ((env[MODEL_VAR[HARNESS]] || "")).trim();
  model = varModel;
  modelSource = varModel ? "repo-config" : "cli-default";
  if (env.TRIVIAL === "1") {
    modelNote = " trivial label has no separate fast tier for " + HARNESS;
  }
}

let effort, effortSource, effortNote = "";
if (Object.prototype.hasOwnProperty.call(seen, "effort")) {
  if (EFFORTS.length === 0) {
    err(2, "harness " + HARNESS + " does not support effort overrides (its non-interactive CLI "
      + "has no effort flag); remove effort= or dispatch " + EFFORT_HARNESSES.map((h) => "@" + h).join(" or "));
  }
  if (!EFFORTS.includes(seen.effort)) {
    err(2, "invalid effort '" + sanitize(seen.effort) + "' for harness " + HARNESS
      + ": expected one of " + EFFORTS.join(", "));
  }
  effort = seen.effort;
  effortSource = "comment-override";
} else if (repoEffort && EFFORTS.length > 0) {
  effort = repoEffort;
  effortSource = "repo-config";
} else {
  if (repoEffort && EFFORTS.length === 0) {
    effortNote = " | AGENT_EFFORT_DEFAULT ignored (" + HARNESS + " has no effort flag)";
  }
  effort = "";
  effortSource = "cli-default";
}

const emit = (k, v) => console.log(k + "=" + v);
emit("AGENT_RESOLVED_HARNESS", HARNESS);
emit("AGENT_RESOLVED_MODEL", model);
emit("AGENT_RESOLVED_EFFORT", effort);

if (HARNESS === "claude") {
  // Endpoint report: the base URL only, never credentials (the auth token
  // is not read here at all). Non-Anthropic endpoints may ignore --effort,
  // so effectiveness is reported as unknown rather than claimed.
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
  emit("ANTHROPIC_DEFAULT_SONNET_MODEL", model);
  emit("ANTHROPIC_DEFAULT_OPUS_MODEL", model);
  emit("ANTHROPIC_DEFAULT_HAIKU_MODEL", flash);
  emit("AGENT_RUN_SUMMARY", summary);
  console.error("model-config: " + summary + modelNote
    + " | effort-effective=" + effectiveness);
} else {
  const summary = "harness=" + HARNESS + " | model=" + (model || "(cli-default)") + " (" + modelSource + ")"
    + " | effort=" + (effort || "(cli-default)") + " (" + effortSource + ")";
  emit("AGENT_RUN_SUMMARY", summary);
  console.error("model-config: " + summary + modelNote + effortNote);
}
NODE
