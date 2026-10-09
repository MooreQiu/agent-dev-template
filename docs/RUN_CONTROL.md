# 运行控制：暂停/取消、预算、拒收恢复与陈旧认领（issue #50）

无人值守运行必须随时可停、可查、可恢复。本文件是 day-two 操作手册：
队列与裁决的语义见 [OPERATIONS.md](OPERATIONS.md)；预算机制的完整契约
见 [BUDGETS.md](BUDGETS.md)，本文件只给操作面。

## 暂停 / 恢复 / 取消

人工控制只靠两个标签，动作是幂等的：

| 动作 | 操作 | 效果 |
|---|---|---|
| 暂停 | 给 issue 加 `agent-paused` | 新分发拒绝启动；**在飞的运行**在下一个阶段门优雅停止：先推送部分成果、释放认领、留评论 |
| 恢复 | 移除 `agent-paused` | 下一次分发正常认领，`prepare` 幂等续作已推送的分支 |
| 取消 | 给 issue 加 `agent-cancelled` | 拒绝启动直到人工清除该标签；outcome 记录 `cancelled` |

两个标签不在 `setup.sh` 的默认清单里，用前先创建（各执行一次）：

```bash
gh label create agent-paused --color BFD4F2
gh label create agent-cancelled --color F9D0C4
```

## 预算耗尽

预算配置在 `.agent/budgets.json`（缺失用默认值；声明了但非法一律
fail-closed，运行拒绝启动）。与"跑到一半停"直接相关的两项：

- `max_attempts_per_issue`（默认 3）：认领即烧掉一次 attempt，崩溃循环
  不可能无限重试；
- `max_repair_rounds`（默认 3）：拒收后自动修复的轮数上限。

耗尽时的行为（`budget_stop` / `budget_exhausted`）：

1. 先 best-effort 推送任务分支上的**部分成果**（远程分支即断点续作点，
   见下一节）；
2. 持久化 outcome（`.agent/runs/task-<issue>-*.json` + Actions Step
   Summary）；
3. 重试预算还有 → 释放认领、`agent-failed` 重新入队；预算耗尽 → 打
   `blocked` 标签并贴 `agent-budget.sh summary` 评论——这是**终态**，
   人类审查后手动移除 `blocked` 才会重新入队。

明确不支持的能力（不要找不存在的开关）：管线在 shell 层看不到 harness
的 token 消耗，**没有货币级成本上限**；需要真实费用上限要等 harness 暴
露用量遥测后再接入。查看生效限额与状态：

```bash
bash scripts/agent-budget.sh limits          # 当前生效的各项上限
bash scripts/agent-budget.sh show <issue>    # refs/agent-status/<issue> 原始 JSON
bash scripts/agent-budget.sh summary <issue> # 人类可读汇总
```

## 拒收 PR 的恢复

`VERDICT: REQUEST_CHANGES` 之后不是终点，而是一个有界的修复循环
（`scripts/pr-repair.sh`，issue #20/#67）：

1. PR 被打 `agent-failed`，修复任务落在**同一个 issue 和同一个分支**上，
   走完整管线（认领 → worktree → harness → 验证 → push）；
2. push 触发 `pr-review.yml` 的 synchronize 事件，自动获得绑定**新 head
   SHA** 的新一轮审查；
3. 轮数由 `max_repair_rounds` 封顶，计数持久化在 `refs/agent-repairs/`
   （CAS 写入，幂等去重）；
4. 过期的拒收反馈不会被修（必须命中 live head），在飞的修复被认领协议去
   重跳过；
5. 反复失败且无进展（验证过的修复没有移动 head）或预算耗尽 → 转入
   `blocked` 终态并留下可操作的证据；人工决定续作时执行
   `bash scripts/pr-repair.sh reset <issue>` 清除修复登记后重新入队。

查看等待修复的 PR：`bash scripts/pr-repair.sh scan`。

## 陈旧认领与手动释放

崩溃、取消或断网的运行会留下**过期租约（stale claim）**：

- 自动回收：nightly sweep（每天 19:37 UTC）在派发前先跑
  `scripts/agent-claim.sh reconcile`——释放租约到期的认领、清理 issue 已
  关闭的成功认领、把 PR 消失的成功认领重新入队，并套用相应标签；
- 手动兜底（急修，不用等 sweep）：

```bash
gh issue edit <n> --remove-label agent-claimed
```

手动释放前先确认没有 agent 还在该 issue 上干活（看认领 ref 与分支活动）：

```bash
bash scripts/agent-claim.sh status <issue>
```

## 保留的部分成果

所有"非正常退出"路径都遵循同一条纪律：**先保住分支，再谈状态**。

- 预算停止、暂停、看门狗终止都会先 best-effort 推送 `agent/issue-<n>`
  分支——推送成功后，远程分支就是断点；
- 恢复时新的运行在 `prepare` 阶段幂等地检出该分支续作，已完成的部分不会
  重做；
- 认领的 lease 续约保证正常长任务不被误回收；只有租约真正过期才会被
  reconcile 拿走。

审查部分成果时直接看 `agent/issue-<n>` 分支的 commit；部分成果的 PR 不会
自动合并——没有通过 review 裁决的代码永远不会进 main。
