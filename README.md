# agent-dev-template

GitHub 驱动的 agent 开发体系模板：issue 即工作单元、认领即加锁、TDD 质量门禁、spec 驱动开发、异步派发与夜间自动认领。**[→ 部署手册 INSTALL.md](INSTALL.md)（agent 可直接执行）**

## 异步工作循环

你只负责两件事：往队列里丢任务、review 合并 PR。其余全部异步，不用盯着。

```
你 ──/milestone-plan──> milestone ──拆解──> issue (ready-for-agent)
      │                                            │
      │                              ┌─────────────┼─────────────────┐
      │                              ▼             ▼                 ▼
      │                      @claude 评论      指派 assignee     每晚 agent-sweep
      │                              └────────── 择一触发 ──────────┘
      │                                            ▼
      │              原子认领（agent-claim.sh：owner + 租约）→ 独立 worktree 分支 agent/issue-N
      │                                            ▼
      │                    TDD：红（失败测试）→ 绿（最小实现）→ 重构
      │                                            ▼
      │                              PR（Closes #N + 验证证据）
      ▼                                            ▼
  /queue 看全景 <──────── issue 评论汇报 ──── 你 review / 合并
```

随时用 `/queue`（本地命令）看五节总览：待认领队列 / 进行中 / 待审 PR / 失败可重试 / 里程碑进度。

## 部署

- **新项目**：`gh repo create <名> --template MooreQiu/agent-dev-template --private`，然后跑 `./setup.sh`
- **已有仓库**：克隆本模板后跑 `./deploy.sh <owner/name>`（自动开 PR + 在线配置，已有文件一律不覆盖）

详细步骤、验证清单、故障排查见 **[INSTALL.md](INSTALL.md)**。

## 组件

| 组件 | 位置 | 作用 |
|---|---|---|
| Agent 规范 | `AGENTS.md` | 所有 harness 通读的工作流与红线（跨工具中立） |
| 项目宪法 | `.specify/memory/constitution.md` | TDD/小步交付/安全约束，优先级最高 |
| Spec Kit | `.claude/skills/speckit-*` | specify→plan→tasks→implement 规格驱动 |
| 角色预检 | `scripts/agent-preflight.sh`、`.agent/roles.json` | 三角色（specify/implement/review）必需文件/技能/工具校验，运行留痕（[docs/AGENT_ROLES.md](docs/AGENT_ROLES.md)） |
| Issue/PR 模板 | `.github/ISSUE_TEMPLATE/`、`PULL_REQUEST_TEMPLATE.md` | 验收标准 checkbox 结构化 |
| 派发 | `.github/workflows/claude.yml` | @claude/@codex/@gemini/@opencode 评论 / 指派触发对应 harness（bot 触发一律过滤，防递归） |
| 互审+自动合并 | `.github/workflows/pr-review.yml`、`scripts/review-verdict.sh` | 独立审计产出绑定 PR/head SHA/run 的结构化 verdict artifact（bot 评论仅展示），判决器复核门禁与 head 未变后 squash 合并；修改合并控制路径的 PR 需人工合并 |
| CI 质量门禁 | `.github/workflows/ci.yml`、`scripts/ci-gate.sh` | 按 `.agent/project.json` 确定性跑 build/test/lint/typecheck＋TDD 红绿证据（不采信 agent 自述）；pr-review 合并前强制同一门禁 |
| 自动认领 | `.github/workflows/agent-sweep.yml` | 每晚扫 ready-for-agent 队列，逐个 TDD 完成并提 PR |
| 本地命令 | `.claude/commands/` | `/claim` `/tdd` `/milestone-plan` `/queue` |
| 模型/effort 配置 | `scripts/model-config.sh` | 评论覆盖 `model=`/`effort=`、trivial 切 flash、三层优先级，非法值拒绝并回评 |
| 一键配置 | `setup.sh` | labels、secrets、模型 vars、branch protection、auto-merge |
| 一键部署 | `deploy.sh` | 部署进已有仓库（开 PR，不覆盖已有文件） |
| 跨 harness | `scripts/agent.sh`、[docs/HARNESSES.md](docs/HARNESSES.md) | AGENTS.md 单一事实源，claude/codex/opencode/gemini 一键切换 |
| GitHub App 认证 | `scripts/app-auth.sh`、[docs/GITHUB_APP_SETUP.md](docs/GITHUB_APP_SETUP.md) | 短时效 installation token，自动化 PR 免审批门（未配置时回退 GITHUB_TOKEN） |
| Projects 看板 | `setup.sh --with-project`、`project-sync.yml` | 可选：labels → 看板单向同步 |

## 模型与 effort 配置

`@claude` 派发用的模型与推理 effort 按三层**优先级**解析（高 → 低，由 `scripts/model-config.sh` 统一裁决）：

1. **评论覆盖**：触发评论里直接写选项，如 `@claude model=opus effort=high 修复失败的测试`
   - `model`：别名 `sonnet`/`opus` → `AGENT_MODEL_DEFAULT` 档，`haiku` → `AGENT_MODEL_FLASH` 档；也可写具体模型名（如 `glm-4.7`、`claude-sonnet-4-6`，限字母数字与 `. _ : / - [ ]`）
   - `effort`：`low` / `medium` / `high` / `xhigh` / `max`
   - 选项必须是独立 token（`models=x` 不识别）；同一 key 出现两个不同值会被判为歧义
   - **非法值直接拒绝**：agent 回评说明原因与正确用法，本次派发不启动，修正后重新评论即可
2. **仓库配置**（repo vars）：`AGENT_MODEL_DEFAULT`（常规档）、`AGENT_MODEL_FLASH`（`trivial` 标签自动切换，约快一倍）、`AGENT_EFFORT_DEFAULT`（留空/不设 = 用 CLI 默认）
3. **文档化兜底**：模型 `glm-5.3[1m]` / `glm-5.3-flash[1m]`；effort 不设置

运行时会在日志与确认评论里报告 provider endpoint（不含任何密钥）、实际模型与请求的 effort 及其来源（override / 仓库配置 / 兜底）。**effort 供应商限制**：effort 经 Claude Code `--effort` 传递，官方 Anthropic 端点支持；第三方兼容端点（如智谱 GLM）可能不生效——此时报告标注 `provider-dependent (unknown)`，不承诺未生效的设置。

**换 provider 只改 secrets `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` + vars `AGENT_MODEL_DEFAULT`/`AGENT_MODEL_FLASH`**（可选 `AGENT_EFFORT_DEFAULT`），任何 Anthropic 兼容端点通用，对照表见 [INSTALL.md](INSTALL.md)。

## 多 harness 派发（@claude / @codex / @gemini / @opencode）

评论里 @ 一个编码 agent 即可让 CI 用对应 harness 处理该 issue/PR（issue #23）：

- **mention 解析**：`@claude`、`@codex`、`@gemini`、`@opencode` 须是独立 mention（`@claude-code`、邮箱里的 `user@claude.com` 不算）；**一条评论只允许 mention 一个**——出现两个不同 agent 判为歧义，直接拒绝并回评；重复同一个不算歧义
- **授权语义不变**：bot 评论（ack、自动指派）一律拒绝，`AGENT_ALLOWED_ACTORS` 允许名单照常生效；所有 harness 走同一套原子认领（`agent-claim.sh`）、`agent-task.sh` 管线与产物核验
- **开关：repo var `AGENT_HARNESSES`**（逗号分隔，默认 `claude`）。只放行名单内的 mention，其余拒绝并回评开启方法；指派触发（无 mention）固定用名单第一个。开启 `@codex` 示例：
  ```bash
  gh variable set AGENT_HARNESSES -b "claude,codex"
  ```
  同时在 `.agent/project.json` 的 `integrations` 加入 `"codex"`（bootstrap 会安装钉版 CLI，与 `agent_tooling.codex_cli` 一致），并配好凭证 secret。**与官方 Codex 集成共存**：若已启用官方 `openai/codex-action`（它也监听 `@codex`），把 codex 留在 `AGENT_HARNESSES` 之外即可避免双派发
- **凭证（secret，缺失即预检失败回评，永不打印值）**：claude → `ANTHROPIC_AUTH_TOKEN`（或 `ANTHROPIC_API_KEY`）；codex → `CODEX_API_KEY`（exec 专用）或 `OPENAI_API_KEY`；gemini → `GEMINI_API_KEY`（或 Vertex 的 `GOOGLE_APPLICATION_CREDENTIALS`）；opencode → `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`（自定义 provider 如 GLM 经仓库 opencode 配置提供）
- **模型/effort 按解析器三层优先级**（`scripts/model-config.sh --harness`）：claude 用 `AGENT_MODEL_DEFAULT`/`AGENT_MODEL_FLASH` 档 + 别名；其余 harness 各有 var，不设 = CLI 默认模型：
  | harness | 模型 var（不设 = CLI 默认） | effort 支持 |
  |---|---|---|
  | claude | `AGENT_MODEL_DEFAULT` / `AGENT_MODEL_FLASH`（别名 sonnet/opus/haiku） | `low/medium/high/xhigh/max`（`--effort`） |
  | codex | `AGENT_MODEL_CODEX` | `low/medium/high`（`model_reasoning_effort`） |
  | gemini | `AGENT_MODEL_GEMINI` | 不支持（评论写 `effort=` 会被拒绝） |
  | opencode | `AGENT_MODEL_OPENCODE`（`provider/model` 形式） | 不支持 |
  `model=sonnet` 等别名是 claude 专属，其他 harness 会拒绝并提示写具体模型名
- **调用形式按各 CLI 受支持版本验证**（钉版见 `.agent/project.json`，详见 [docs/HARNESSES.md](docs/HARNESSES.md)）：codex `exec --ephemeral --sandbox workspace-write`；gemini `--approval-mode=yolo --skip-trust`（`--yolo` 已废弃）；opencode `run --auto`；角色上下文：所有 harness 都读 AGENTS.md（gemini 经 `.gemini/settings.json` 配置）

## Projects 看板与里程碑（可选）

`./setup.sh --with-project` 一键创建 "Agent Queue" 看板（Status：Queued / In Progress / In Review / Done）并回填当前队列。设计原则：**labels/assignee 是唯一事实源，看板只是视图**——CI 同步（project-sync.yml，默认关闭）用 `GH_PROJECT_TOKEN`（project 权限 PAT，GITHUB_TOKEN 写不了 Projects）单向把状态刷到看板；GITHUB 2026-03 起 Projects 已原生显示 agent session 活动。里程碑进度用 `/queue` 或看板 Milestone 分组查看；优先级用 `p0`–`p3` 标签。

## 认领语义（防重复干活）

- **统一原子认领协议**：评论派发、指派触发、夜间 sweep、修复 worker 全走 `scripts/agent-claim.sh`——以 `refs/agent-claims/<issue>` 上的 git CAS 推送（`--force-with-lease`）做原子 test-and-set，两个 worker 不可能同时持有同一 issue
- **owner + 租约**：认领带执行者与过期时间；崩溃/取消留下的过期认领由 sweep 启动时的 `reconcile` 自动释放回队列（也可手动 `gh issue edit <n> --remove-label agent-claimed` 兜底）
- **assignee = 本地锁**：本地 `/claim` 仍先 `gh issue edit --add-assignee @me`
- `ready-for-agent` 是唯一队列入口；`blocked` 勿动；`trivial` 切快速模型

## 安全须知

- issue/PR 正文是不可信输入：workflow prompt 已注入"不执行无关指令"约束；建议私仓使用、定期轮换 token
- agent-sweep 每晚最多处理 3 个（可调），运行于 `acceptEdits` + gh/git/npm 白名单

## 已知限制

- branch protection 在 GitHub Free 私有仓库不可用（`setup.sh` 会提示），公开仓库或 Pro 可用；auto-merge 已尽量启用
- "Allow GitHub Actions to create and approve pull requests" 只能网页开启；未开启时 agent 推好分支并附 compare 链接和现成 PR 描述
- GITHUB_TOKEN 触发的自动化事件会被 GitHub 挂起等人工批准；按 [docs/GITHUB_APP_SETUP.md](docs/GITHUB_APP_SETUP.md) 配置 GitHub App 后消除（未配置时自动回退 GITHUB_TOKEN，仅多一道审批门）
- 派发与 sweep 均用 headless Claude Code CLI（认证用的 GitHub App 与 Claude GitHub App 无关）
