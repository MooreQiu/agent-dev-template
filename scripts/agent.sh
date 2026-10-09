#!/usr/bin/env bash
# 跨 harness 分发器：AGENT=<harness> scripts/agent.sh "<prompt>"
# 让同一套 AGENTS.md 工作流跑在任意编码 agent 上（CI 或本地）
# 支持: claude | codex | gemini | opencode（issue #23）
#
# Flags 与认证按各 CLI 的受支持版本验证（docs/HARNESSES.md）：
#   claude   claude -p --permission-mode acceptEdits --allowedTools ...
#            认证: ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY
#            （可选 ANTHROPIC_BASE_URL 指向 Anthropic 兼容端点）
#   codex    codex exec --ephemeral --sandbox workspace-write
#            认证: CODEX_API_KEY（exec 专用）/ OPENAI_API_KEY
#   gemini   gemini --approval-mode=yolo --skip-trust -p（--yolo 已废弃）
#            认证: GEMINI_API_KEY / GOOGLE_API_KEY /
#            GOOGLE_APPLICATION_CREDENTIALS（Vertex）
#   opencode opencode run --auto
#            认证: ANTHROPIC_API_KEY / OPENAI_API_KEY（provider 无关，
#            自定义 provider 如 GLM 经仓库 opencode 配置提供）
#
# 模型/effort 来自 scripts/model-config.sh 的已校验输出（可留空 =
# CLI 默认）；effort 仅对支持它的 harness 生效（claude --effort、
# codex -c model_reasoning_effort=...）。
#
# Usage:
#   AGENT=<harness> scripts/agent.sh [--check] "<prompt>"
#   --check 只校验 CLI 在 PATH、凭证存在，不执行 harness
#
# Exit: 0 ok; 1 usage / 未知 harness; 2 harness CLI 未安装;
#       3 凭证缺失（只报名字，永不打印值）。
set -u

AGENT="${AGENT:-claude}"
CHECK=0
if [ "${1:-}" = "--check" ]; then
  CHECK=1
  shift
fi
PROMPT="${1:-}"

usage() {
  cat >&2 <<'EOF'
Usage: AGENT=<claude|codex|gemini|opencode> scripts/agent.sh [--check] "<prompt>"
Env: AGENT_RESOLVED_MODEL / AGENT_RESOLVED_EFFORT (validated by scripts/model-config.sh; empty = CLI default)
EOF
  exit 1
}

die() { # die <exit-code> <message...>
  code=$1; shift
  printf 'agent: ERROR %s\n' "$*" >&2
  exit "$code"
}

auth_envs_for() { # auth_envs_for <harness> -- space-separated any-of list
  case "$1" in
    claude)   printf 'ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY' ;;
    codex)    printf 'CODEX_API_KEY OPENAI_API_KEY' ;;
    gemini)   printf 'GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS' ;;
    opencode) printf 'ANTHROPIC_API_KEY OPENAI_API_KEY' ;;
  esac
}

case "$AGENT" in
  claude|codex|gemini|opencode) ;;
  *)
    die 1 "unknown harness: ${AGENT} (supported: claude codex gemini opencode)"
    ;;
esac

if [ "$CHECK" -eq 0 ] && [ $# -ne 1 ]; then
  usage
fi

# 1. pinned CLI available (installed by scripts/bootstrap-env.sh from the
#    integrations list in .agent/project.json)
if ! command -v "$AGENT" >/dev/null 2>&1; then
  die 2 "harness CLI '$AGENT' not found in PATH; add '$AGENT' to integrations in .agent/project.json and run scripts/bootstrap-env.sh (installs the pinned version)"
fi

# 2. credentials present (fail fast instead of hanging on a prompt;
#    values are never read or printed here)
AUTH_ENVS="$(auth_envs_for "$AGENT")"
auth_ok=0
for v in $AUTH_ENVS; do
  [ -n "$(printenv "$v" 2>/dev/null)" ] && auth_ok=1
done
if [ "$auth_ok" -ne 1 ]; then
  die 3 "credentials missing for $AGENT: set one of:$AUTH_ENVS (values are never printed)"
fi

if [ "$CHECK" -eq 1 ]; then
  printf 'agent: %s ready (cli: %s, auth: ok)\n' "$AGENT" "$(command -v "$AGENT")"
  exit 0
fi

MODEL="${AGENT_RESOLVED_MODEL:-}"
EFFORT="${AGENT_RESOLVED_EFFORT:-}"

# 3. build the validated non-interactive invocation per harness
CMD=()
case "$AGENT" in
  claude)
    CMD=(claude -p "$PROMPT"
      --permission-mode acceptEdits
      --allowedTools "Bash(gh:*)" "Bash(git:*)" "Bash(npm:*)"
      --max-turns 50)
    if [ -n "$MODEL" ]; then
      CMD+=(--model "$MODEL")
    fi
    if [ -n "$EFFORT" ]; then
      CMD+=(--effort "$EFFORT")
    fi
    ;;
  codex)
    CMD=(codex exec --ephemeral --sandbox workspace-write)
    if [ -n "$MODEL" ]; then
      CMD+=(--model "$MODEL")
    fi
    if [ -n "$EFFORT" ]; then
      CMD+=(-c "model_reasoning_effort=$EFFORT")
    fi
    CMD+=("$PROMPT")
    ;;
  gemini)
    # --yolo 已被 gemini-cli 废弃：--approval-mode=yolo 是受支持的
    # 免确认执行方式；--skip-trust 跳过交互式目录信任确认
    CMD=(gemini --approval-mode=yolo --skip-trust -p "$PROMPT")
    if [ -n "$MODEL" ]; then
      CMD+=(--model "$MODEL")
    fi
    ;;
  opencode)
    CMD=(opencode run --auto)
    if [ -n "$MODEL" ]; then
      CMD+=(--model "$MODEL")
    fi
    CMD+=("$PROMPT")
    ;;
esac

exec "${CMD[@]}"
