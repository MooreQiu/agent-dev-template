#!/usr/bin/env bash
# Dispatch gate for Claude Dispatch (issue #13).
#
# Allows only human-initiated triggers. Bots (github-actions[bot], GitHub App
# bots such as <app-slug>[bot]) can never pass, so acknowledgement comments
# containing @claude, automated assignments, and other bot activity cannot
# recursively start duplicate work once workflows stop using GITHUB_TOKEN.
#
# Usage:
#   GITHUB_EVENT_NAME=issue_comment GITHUB_EVENT_PATH=event.json \
#     scripts/dispatch-filter.sh
#   (or pass the payload path and event name as arguments)
#
# Optional env:
#   AGENT_ALLOWED_ACTORS  comma-separated logins allowed to trigger dispatch;
#                         empty (default) allows any human caller
#
# Prints "allow: <reason>" or "deny: <reason>" and exits 0 on allow, 1 on deny.
# Fails closed on unreadable payloads and unhandled event types.

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

  let ev;
  try { ev = JSON.parse(fs.readFileSync(path, "utf8")); }
  catch (e) { deny("unreadable event payload: " + e.message); }
  const sender = ev.sender || {};

  if (eventName === "issue_comment") {
    if (ev.action !== "created") deny("comment action is " + ev.action + ", not created");
    const body = ((ev.comment || {}).body) || "";
    if (!body.includes("@claude")) deny("comment does not mention @claude");
    const author = (ev.comment || {}).user;
    if (isBot(author)) deny("comment author is a bot (" + ((author || {}).login || "unknown") + ")");
    if (isBot(sender)) deny("event sender is a bot (" + (sender.login || "unknown") + ")");
    if (!allowedByList(sender)) deny("sender " + (sender.login || "unknown") + " is not in AGENT_ALLOWED_ACTORS");
    console.log("allow: human @" + (sender.login || "?") + " mentioned @claude");
  } else if (eventName === "issues") {
    if (ev.action !== "assigned") deny("issue action is " + ev.action + ", not assigned");
    const labels = ((ev.issue || {}).labels || [])
      .map((l) => (l && l.name) || l || "");
    if (!labels.includes("ready-for-agent")) deny("issue lacks the ready-for-agent label");
    if (isBot(ev.assignee)) deny("assignee is a bot (" + ((ev.assignee || {}).login || "unknown") + ")");
    if (isBot(sender)) deny("event sender is a bot (" + (sender.login || "unknown") + ")");
    if (!allowedByList(sender)) deny("sender " + (sender.login || "unknown") + " is not in AGENT_ALLOWED_ACTORS");
    console.log("allow: human @" + (sender.login || "?") + " assigned an issue labeled ready-for-agent");
  } else {
    deny("unhandled event type " + (eventName || "(none)"));
  }
' "$event_path" "$event_name"
