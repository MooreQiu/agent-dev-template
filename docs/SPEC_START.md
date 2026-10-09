# Spec Start：从已审批规格启动自主规划与 issue 生成

issue #16 的落地说明：把"人工审批过的 spec"变成"可被 agent 认领的 issue 队列"。入口是 `scripts/spec-start.sh`，Actions 连接是 `.github/workflows/spec-start.yml`（workflow_dispatch，人工触发）。

## 流程总览

```
人工审批 spec（提交 approval.json，记录不可变 revision）
  → workflow_dispatch 触发 spec-start.yml（输入 spec 路径 + revision）
  → 预检 specify 角色（scripts/agent-preflight.sh verify specify）
  → 缺 plan.md / tasks.md 时由规划 agent 自主生成（/speckit-plan、/speckit-tasks）
  → scripts/spec-start.sh 校验门禁后把 tasks.md 转成 issues
  → 生成物打上 ready-for-agent（进入调度队列，#17 负责排序）
```

## 审批记录（approval.json）

spec 所在 feature 目录下必须有人工写入的 `specs/<feature>/approval.json`：

```json
{
  "spec": "specs/016-demo/spec.md",
  "revision": "<审批时 spec 内容所在的完整 commit SHA>",
  "approved_by": "<审批人登录名>",
  "approved_at": "2026-10-09T00:00:00Z"
}
```

审批是**不可变锚点**：入口会同时校验（1）记录中的 `revision` 与调用参数一致；（2）当前工作区的 spec 内容哈希等于该 revision 里的 blob。任一不成立即失败——**绝不静默替换已审批的需求**，改动 spec 必须重新审批。

## 入口用法

```bash
scripts/spec-start.sh specs/<feature>/spec.md <approved-revision> [--dry-run] [--json]
```

| 选项 | 含义 |
|---|---|
| `--dry-run` | 只跑门禁并打印将要创建的内容，不访问 gh |
| `--json` | stdout 输出单行 JSON 摘要（给 #17 调度器消费），人类可读日志走 stderr |

退出码：`0` 成功；`1` 门禁失败（审批缺失/不匹配、spec 过期、tasks 非法）；`2` 用法错误；`3` planning 前提未满足（缺 plan.md / tasks.md，workflow 据此触发自主规划）。

## 规划决策政策

规划（生成 plan.md / tasks.md）在 CI 中由 agent 以 **specify 角色**执行（角色与技能映射见 `.agent/roles.json` 与 [AGENT_ROLES.md](AGENT_ROLES.md)；spec 理解与规划阶段的模型分配见 issue #10）：

- Planning proceeds autonomously within approved constraints; genuinely
  unresolved requirements are reported as blocked instead of asking routine
  questions in CI.
- 具体地：凡在已审批 spec、constitution 与模板约定内能定的事（实现顺序、文件组织、命名等），agent 自主选择最简单的方案并把决策记录进 plan.md，**不在 CI 里提问**。
- 只有"真正的未解决需求"才算 blocked：spec 缺少某项必需需求、两条已审批需求互相矛盾、任务依赖的 task ID 在 tasks.md 中不存在等。此时规划 agent 停止并报告 `BLOCKED: <原因>`；issue 生成侧则给对应任务打 `blocked` 标签并在正文写明未解决项，而不是编造要求或拉人进循环。

## Issue 生成格式

- **身份限定**：每个任务的全局唯一身份是 `<feature>/T###`（如 `016-demo/T001`），issue 标题形如 `[016-demo/T001] 任务描述`。去重按这个完整 token 匹配，因此不同 feature 的 `T001` 不会冲突。
- **幂等去重**：入口用 `gh issue list --state all`（含 closed）拉取现有标题做前缀匹配，已存在的任务跳过不重建；tasks.md 中已勾选（`- [x]`）的任务视为已完成，同样跳过。重跑安全。
- **正文结构**：`## Acceptance criteria`（来自任务行）、`## Spec references`（spec 路径 @ 审批 SHA、plan/tasks 路径、任务身份）、`## Dependencies`（`Depends: #N ...`；未解决的依赖单独列出）、`## Scheduling`（调度契约说明）。
- **里程碑**：issue 挂到以 feature 目录名命名的 milestone（不存在时通过 `gh api repos/<repo>/milestones` 创建）。
- **调度资格**：正常任务打 `ready-for-agent` 进入队列；有未解决依赖的任务打 `blocked`，不进队列。
- **远程访问**：只用 gh CLI（`gh issue list` / `gh issue create` / `gh api`），不假设存在未配置的 GitHub MCP。

`--json` 输出示例：

```json
{"feature":"016-demo","spec":"specs/016-demo/spec.md","revision":"<sha>","created":[11,12],"skipped":["016-demo/T001"],"blocked":["016-demo/T004"],"would_create":[],"dry_run":false}
```

## 验收测试

`tests/test-spec-start.sh`（`npm test` 一并运行）：缺失审批、revision 不匹配、spec 过期、revision 不含 spec、重跑幂等（含 closed issue）、跨 feature T001 不冲突、issue 转换格式（标题/正文/标签/里程碑/依赖）、planning 前提未满足、JSON 结构化输出、gh-only 远程访问。
