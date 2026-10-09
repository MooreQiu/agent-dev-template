# 跨 Harness 指南

本模板的核心规范写在 **AGENTS.md**（agents.md 标准，Linux 基金会 Agentic AI Foundation 托管，20+ 工具原生读取），天然跨 harness。换工具不用换流程。

## 各 harness 对 AGENTS.md 的支持

| Harness | 读 AGENTS.md | 说明 |
|---|---|---|
| OpenAI Codex | 原生（标准发源地，32 KiB 上限） | `codex exec` 跑 CI |
| OpenCode | 原生（主配置；CLAUDE.md 仅作 fallback） | 还能直接读 `.claude/skills` |
| Cursor / Amp / Jules / Windsurf / Zed / Devin / Copilot coding agent 等 | 原生 | 见 agents.md 生态列表 |
| Gemini CLI | 需配置 | `.gemini/settings.json` 里 `context.fileName: ["AGENTS.md","GEMINI.md"]` |
| Claude Code | 有 CLAUDE.md 时不读 | 所以本仓库 CLAUDE.md 首行是 `@AGENTS.md` 导入 |

## 本仓库的跨 harness 布局

```
AGENTS.md                    # 唯一事实源（所有 harness 通用）
CLAUDE.md                    # 一行 @AGENTS.md 导入 + Claude 专属补充
scripts/agent.sh             # 分发器：AGENT=<名> 即切换 harness 执行同一 prompt
scripts/agent-preflight.sh   # 角色预检（specify/implement/review）+ 运行记录
scripts/sync-skills.sh       # .claude/skills → .codex/skills 同步 + 清单哈希
.claude/commands/            # Claude 命令（/claim /tdd /milestone-plan /queue）
.claude/skills/              # speckit 技能（单一维护源，Claude Code 自动发现）
.codex/skills/               # Codex 副本（由 sync-skills.sh 镜像，$speckit-* 调用）
.agent/roles.json            # 角色 → 指令/产物/技能/工具映射（见 docs/AGENT_ROLES.md）
.specify/                    # spec-kit：claude + codex 双集成
```

本地/CI 一键切换：

```bash
AGENT=claude   scripts/agent.sh "按 AGENTS.md 处理 issue #5"
AGENT=codex    scripts/agent.sh "按 AGENTS.md 处理 issue #5"   # 需 CODEX_API_KEY
AGENT=opencode scripts/agent.sh "按 AGENTS.md 处理 issue #5"   # provider 无关，支持 GLM 端点
AGENT=gemini   scripts/agent.sh "按 AGENTS.md 处理 issue #5"   # 需 GEMINI_API_KEY
```

## CI 里换 harness（等价替换 claude.yml 的安装+执行两步）

**Codex**
```yaml
- run: npm i -g @openai/codex
- run: codex exec --sandbox workspace-write --ephemeral "处理 issue #N，按 AGENTS.md"
  env: { CODEX_API_KEY: "${{ secrets.CODEX_API_KEY }}" }
```

**OpenCode**
```yaml
- run: npm i -g opencode-ai
- run: opencode run --auto "处理 issue #N，按 AGENTS.md"
  env: { ANTHROPIC_API_KEY: "${{ secrets.ANTHROPIC_API_KEY }}" }
```

**Gemini CLI**
```yaml
- run: npm i -g @google/gemini-cli
- run: gemini --yolo -p "处理 issue #N，按 AGENTS.md"
  env: { GEMINI_API_KEY: "${{ secrets.GEMINI_API_KEY }}" }
```

OpenCode 还有官方 GitHub 集成：`opencode github install` 自动生成 Actions workflow。

## Spec Kit 多集成共存

本仓库已内置 claude + codex 双集成（`.specify/integration.json`），Codex 侧技能由 `scripts/sync-skills.sh` 从 `.claude/skills` 镜像维护，不需要在线加装。

```bash
uvx --from git+https://github.com/github/spec-kit.git specify integration install codex     # 加装 codex 的 $speckit-* skills
uvx --from git+https://github.com/github/spec-kit.git specify integration install gemini    # 加装 .gemini/commands
uvx --from git+https://github.com/github/spec-kit.git specify integration status --json     # CI 检查
```

40+ 集成可共存于同一仓库；命令格式翻译（`/claim` ↔ `$claim`）由各集成自动完成。

## 已知差异

- 权限模型不同：claude 用 `--permission-mode acceptEdits --allowedTools`；codex 用 `--sandbox workspace-write`；opencode 用 `--auto`；gemini 用 `--yolo`。scripts/agent.sh 已封装
- 模型上下文上限不同（AGENTS.md 32 KiB 建议保持精简——本仓库已满足）

来源：[agents.md](https://agents.md/) · [Claude Code memory 文档](https://code.claude.com/docs/en/memory) · [Codex agents-md](https://developers.openai.com/codex/guides/agents-md) · [OpenCode rules](https://opencode.ai/docs/rules/) · [Spec Kit integrations](https://github.com/github/spec-kit/blob/main/docs/reference/integrations.md)
