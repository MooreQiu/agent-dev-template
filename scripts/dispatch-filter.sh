#!/usr/bin/env bash
# Dispatch gate for agent mention dispatch (issues #13 and #23).
#
# Allows only human-initiated triggers and resolves which agent harness a
# comment dispatches. Bots (github-actions[bot], GitHub App bots such as
# <app-slug>[bot]) can never pass, so acknowledgement comments repeating
# the mention, automated assignments, and other bot activity cannot
# recursively start duplicate work once workflows stop using GITHUB_TOKEN.
#
# Mention parsing (issue #23):
#   - recognized commands are @claude, @codex, @gemini, and @opencode as
#     standalone mentions (word-bounded; "@claude-code" or an email like
#     "user@claude.com" is not a mention)
#   - a comment must mention exactly one distinct harness: multiple
#     distinct mentions are rejected deterministically as ambiguous,
#     repeated identical mentions are fine
#   - AGENT_HARNESSES (comma-separated repo var, default "claude") gates
#     which mentions dispatch. Keeping codex out of it while the official
#     openai/codex-action integration handles @codex prevents double
#     dispatch; the assignment path always uses the first enabled entry
#
# Usage:
#   GITHUB_EVENT_NAME=issue_comment GITHUB_EVENT_PATH=event.json \
#     scripts/dispatch-filter.sh
#   (or pass the payload path and event name as arguments)
#
# Optional env:
#   AGENT_ALLOWED_ACTORS  comma-separated logins allowed to trigger dispatch;
#                         empty (default) allows any human caller
#   AGENT_HARNESSES       comma-separated harnesses dispatchable by mention
#                         (claude, codex, gemini, opencode; default claude)
#
# On allow, prints "allow: <reason>" followed by "harness=<name>" (for the
# workflow to capture as a step output). On deny, prints "deny: <reason>".
# Exits 0 on allow, 1 on deny. Fails closed on unreadable payloads,
# unhandled event types, and unknown AGENT_HARNESSES entries.

event_path="${1:-${GITHUB_EVENT_PATH:-}}"
event_name="${2:-${GITHUB_EVENT_NAME:-}}"

node -e '
  const fs = require("fs");
  const [path, eventName] = process.argv.slice(1);
  const allowed = (process.env.AGENT_ALLOWED_ACTORS || "")
    .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  const deny = (r) => { console.log("deny: " + r); process.exit(1); };
  const isBot = (u) =>
    !u || u.type === "Bot" || /(\[bot\]|-bot)$/.test(u.login || "");
  const allowedByList = (u) =>
    allowed.length === 0 || allowed.includes((u.login || "").toLowerCase());

  // Mention registry: name doubles as the harness CLI binary name.
  const MENTIONS = ["claude", "codex", "gemini", "opencode"];
  const enabledRaw = (process.env.AGENT_HARNESSES || "")
    .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  const enabled = enabledRaw.length ? enabledRaw : ["claude"];
  for (const h of enabled) {
    if (!MENTIONS.includes(h)) {
      deny("unknown harness '" + h + "' in AGENT_HARNESSES (supported: "
        + MENTIONS.join(", ") + "); fix it with: gh variable set AGENT_HARNESSES -b <comma-separated list>");
    }
  }
  // A standalone mention: not preceded by a word character or @ (emails,
  // usernames) and not followed by a username character ("@claude-code").
  const mentionIn = (body) => MENTIONS.filter((m) =>
    new RegExp("(^|[^A-Za-z0-9_@])@" + m + "(?![A-Za-z0-9_-])").test(body));

  let ev;
  try { ev = JSON.parse(fs.readFileSync(path, "utf8")); }
  catch (e) { deny("unreadable event payload: " + e.message); }
  const sender = ev.sender || {};

  if (eventName === "issue_comment") {
    if (ev.action !== "created") deny("comment action is " + ev.action + ", not created");
    const body = ((ev.comment || {}).body) || "";
    const mentionedInBody = mentionIn(body);
    if (mentionedInBody.length === 0) {
      deny("comment does not mention a dispatchable agent ("
        + MENTIONS.map((m) => "@" + m).join(", ") + ")");
    }
    if (mentionedInBody.length > 1) {
      deny("ambiguous comment mentions " + mentionedInBody.map((m) => "@" + m).join(" and ")
        + "; mention exactly one agent per comment");
    }
    const harness = mentionedInBody[0];
    const author = (ev.comment || {}).user;
    if (isBot(author)) deny("comment author is a bot (" + ((author || {}).login || "unknown") + ")");
    if (isBot(sender)) deny("event sender is a bot (" + (sender.login || "unknown") + ")");
    if (!allowedByList(sender)) deny("sender " + (sender.login || "unknown") + " is not in AGENT_ALLOWED_ACTORS");
    if (!enabled.includes(harness)) {
      deny("@" + harness + " dispatch is not enabled (AGENT_HARNESSES="
        + (enabledRaw.length ? enabledRaw.join(",") : "(default claude)")
        + "); enable it with: gh variable set AGENT_HARNESSES -b "
        + enabled.concat(harness).join(",")
        + (harness === "codex"
          ? ". Leave codex out while the official openai/codex-action integration handles @codex mentions, or both will dispatch."
          : "."));
    }
    console.log("allow: human @" + (sender.login || "?") + " mentioned @" + harness);
    console.log("harness=" + harness);
  } else if (eventName === "issues") {
    if (ev.action !== "assigned") deny("issue action is " + ev.action + ", not assigned");
    const labels = ((ev.issue || {}).labels || [])
      .map((l) => (l && l.name) || l || "");
    if (!labels.includes("ready-for-agent")) deny("issue lacks the ready-for-agent label");
    if (isBot(ev.assignee)) deny("assignee is a bot (" + ((ev.assignee || {}).login || "unknown") + ")");
    if (isBot(sender)) deny("event sender is a bot (" + (sender.login || "unknown") + ")");
    if (!allowedByList(sender)) deny("sender " + (sender.login || "unknown") + " is not in AGENT_ALLOWED_ACTORS");
    // No mention to resolve on the assignment path: the first enabled
    // harness is the repository default agent (deterministic).
    console.log("allow: human @" + (sender.login || "?") + " assigned an issue labeled ready-for-agent");
    console.log("harness=" + enabled[0]);
  } else {
    deny("unhandled event type " + (eventName || "(none)"));
  }
' "$event_path" "$event_name"
