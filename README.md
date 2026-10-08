# agent-dev-template

GitHub 驱动的 agent 开发体系模板：issue 即工作单元、认领即加锁、TDD 质量门禁、spec 驱动开发、CI 自动派发与夜间自动认领。

```
人 ──创建──> milestone ──拆解──> issue (ready-for-agent)
                                        │
              ┌─────────────────────────┼──────────────────────────┐
              ▼                         ▼                          ▼
      @claude 评论触发          指派 assignee 触发           每晚 agent-sweep
      (claude.yml)             (claude.yml)                  自动认领队列
              └──────────────── motivation ────────────────────────┘
                                        ▼
                    认领锁(assignee/agent-claimed) → 分支 agent/issue-N
                                        ▼
                    TDD：红(失败测试) → 绿(最小实现) → 重构
                                        ▼
                    PR(Closes #N + 验证证据) → CI 门禁 → auto-merge
```

## 快速开始

```bash
# 1. 用本模板建仓（或 gh repo create myproj --template MooreQiu/agent-dev-template）
# 2. 一键配置（labels、secrets、branch protection、auto-merge）
ANTHROPIC_AUTH_TOKEN=<你的智谱key> ./setup.sh
# 3. 换掉 AGENTS.md 里的"项目信息"占位（构建/测试命令）
# 4. 开一个 issue 用 "🤖 Agent 任务" 模板 → 自动带 ready-for-agent 标签
# 5. 触发 agent，任选其一：
#    a) 在 issue 评论 @claude 干活
#    b) 把 issue 指派给任何人（保持 ready-for-agent 标签）
#    c) 什么都不做，等每晚 agent-sweep 自动认领（也可手动 Run workflow）
```

## 组件

| 组件 | 位置 | 作用 |
|---|---|---|
| Agent 规范 | `AGENTS.md` | 所有 agent 必读的工作流与红线 |
| 项目宪法 | `.specify/memory/constitution.md` | TDD/小步交付/安全约束，优先级最高 |
| Spec Kit | `.claude/skills/speckit-*` | specify→plan→tasks→implement 规格驱动 |
| Issue 模板 | `.github/ISSUE_TEMPLATE/` | bug / feature / agent 任务（含验收标准） |
| PR 模板 | `.github/PULL_REQUEST_TEMPLATE.md` | 摘要 + 关联 issue + 验证证据 |
| 派发 | `.github/workflows/claude.yml` | @claude 提及 / 指派触发 Claude Code Action |
| 自动认领 | `.github/workflows/agent-sweep.yml` | 每晚扫 ready-for-agent 队列，逐个 TDD 完成并提 PR |
| 本地命令 | `.claude/commands/` | `/claim` `/tdd` `/milestone-plan` |
| 一键配置 | `setup.sh` | labels、secrets、branch protection、auto-merge |

## 双触发认领语义（防重复干活）

- **assignee = 锁**：本地 `/claim` 与 Action 都先 `gh issue edit --add-assignee @me`
- **CI sweep 用 `agent-claimed` 标签做锁**（GITHUB_TOKEN 无法指派给真人），失败自动摘标签回到队列
- `ready-for-agent` 是唯一工作队列入口；`blocked` 表示勿动

## 模型配置

Workflows 通过 repo secrets 走 GLM（`ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`，与本地 Claude Code 同一套环境变量）。换模型只改 `claude.yml` / `agent-sweep.yml` 顶部的 env 映射。

## 安全须知

- issue/PR 正文是不可信输入，workflow 中已注入"不执行无关指令"的约束，但仍建议私仓使用、定期轮换 token、CI 用最小权限
- `agent-sweep` 每晚最多处理 3 个 issue（可在 workflow_dispatch 调整），跑在 `acceptEdits` + gh/git 白名单下

## 已知限制

- branch protection / auto-merge 在 GitHub Free 私有仓库不可用（`setup.sh` 会提示），公开仓库或 Pro 可用
- claude-code-action 走第三方 (base URL) 端点时，首次跑请确认 Actions 日志中模型调用正常
