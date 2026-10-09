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
| 派发 | `.github/workflows/claude.yml` | @claude 评论 / 指派触发 headless Claude Code（免 GitHub App） |
| 互审+自动合并 | `.github/workflows/pr-review.yml` | agent PR 独立审计（跑测试、贴 verdict），APPROVE 自动合并 |
| CI 质量门禁 | `.github/workflows/ci.yml`、`scripts/ci-gate.sh` | 按 `.agent/project.json` 确定性跑 build/test/lint/typecheck＋TDD 红绿证据（不采信 agent 自述）；pr-review 合并前强制同一门禁 |
| 自动认领 | `.github/workflows/agent-sweep.yml` | 每晚扫 ready-for-agent 队列，逐个 TDD 完成并提 PR |
| 本地命令 | `.claude/commands/` | `/claim` `/tdd` `/milestone-plan` `/queue` |
| 模型分级 | workflow 运行时解析 | `trivial` 标签自动切 flash 快速模型 |
| 一键配置 | `setup.sh` | labels、secrets、模型 vars、branch protection、auto-merge |
| 一键部署 | `deploy.sh` | 部署进已有仓库（开 PR，不覆盖已有文件） |
| 跨 harness | `scripts/agent.sh`、[docs/HARNESSES.md](docs/HARNESSES.md) | AGENTS.md 单一事实源，claude/codex/opencode/gemini 一键切换 |
| Projects 看板 | `setup.sh --with-project`、`project-sync.yml` | 可选：labels → 看板单向同步 |

## 模型分级与换 provider

- **trivial 分级**：issue 打 `trivial` 标签 → 自动用 flash 快速模型（约快一倍），适合文档/配置类小任务
- **换 provider 只改 4 个值**：secrets `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` + vars `AGENT_MODEL_DEFAULT`/`AGENT_MODEL_FLASH`，任何 Anthropic 兼容端点通用，对照表见 [INSTALL.md](INSTALL.md)

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
- 派发与 sweep 均用 headless Claude Code CLI（不依赖 Claude GitHub App）
