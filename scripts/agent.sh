#!/usr/bin/env bash
# 跨 harness 分发器：AGENT=<harness> scripts/agent.sh "<prompt>"
# 让同一套 AGENTS.md 工作流跑在任意编码 agent 上（CI 或本地）
# 支持: claude | codex | opencode | gemini
set -euo pipefail

AGENT="${AGENT:-claude}"
PROMPT="${1:?用法: AGENT=<claude|codex|opencode|gemini> scripts/agent.sh \"<prompt>\"}"

case "$AGENT" in
  claude)
    # 认证: ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN（或官方 ANTHROPIC_API_KEY）
    exec claude -p "$PROMPT" \
      --permission-mode acceptEdits \
      --allowedTools "Bash(gh:*)" "Bash(git:*)" "Bash(npm:*)" \
      --max-turns 60
    ;;
  codex)
    # 认证: CODEX_API_KEY（OpenAI；或 openai/codex-action@v1 代理）
    exec codex exec --sandbox workspace-write --ephemeral "$PROMPT"
    ;;
  opencode)
    # 认证: ANTHROPIC_API_KEY / OPENAI_API_KEY / OPENCODE_API_KEY（provider 无关，支持 GLM 等 Anthropic 兼容端点）
    exec opencode run --auto "$PROMPT"
    ;;
  gemini)
    # 认证: GEMINI_API_KEY（或 Vertex: GOOGLE_APPLICATION_CREDENTIALS + GOOGLE_CLOUD_PROJECT）
    exec gemini --yolo -p "$PROMPT"
    ;;
  *)
    echo "未知 harness: $AGENT（支持 claude / codex / opencode / gemini）" >&2
    exit 1
    ;;
esac
