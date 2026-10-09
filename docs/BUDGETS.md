# 自主运行预算与可观测状态（issue #22）

无人值守的自主运行必须有边界：本仓库用项目级预算 + 仓库内持久状态约束
`scripts/agent-task.sh` 管线的每一次运行，超限即停止并留下人类可读的
结论，绝不无限重试、绝不依赖外部通知渠道。

## 预算配置（`.agent/budgets.json`）

| 限制 | 含义 | 默认 |
|---|---|---|
| `max_attempts_per_issue` | 每个 issue 允许的自主运行次数（重试预算） | 3 |
| `max_repair_rounds` | reconcile 驱动的重新入队次数（租约过期、PR 消失） | 3 |
| `max_convergence_rounds` | 收敛修复轮数的项目策略值（对应 `spec-converge.sh --budget`） | 2 |
| `max_elapsed_seconds_per_run` | 单次运行墙钟预算；看门狗到点终止失控 harness | 10800 |
| `max_steps_per_run` | 单次运行的管线阶段数（claim→prepare→execute→verify） | 8 |

规则：

- 文件缺失时使用上表默认值；文件中声明了某限制但取值不是正整数时**一律
  fail-closed**（`agent-budget.sh` 报错退出，运行拒绝启动），绝不会退化成
  无限制运行。
- 复制模板到具体项目后按需修改 `.agent/budgets.json`；命令行查看生效值：
  `bash scripts/agent-budget.sh limits`。

### 成本估算的局限（必须知道）

- 管线在 shell 层无法观测 harness（claude/codex 等）的 token 消耗或 API
  计费数据，因此**没有货币级的成本上限**。可测量的等价代理是调用次数：
  `attempts`（harness 启动次数）与 `repair_rounds`（修复轮数），由上述
  预算封顶；单次调用的爆炸半径再由时长/步数预算约束。
- 若需要真实 token/费用上限，需 harness 自身暴露用量遥测并在
  `agent-budget.sh check` 中接入——当前版本明确不支持，不假装支持。

## 执行点：预算在何处被检查

`agent-task.sh run` 的每次执行：

1. **preflight（认领前）**：读取 `agent-budget.sh check <key>` —— 项目级
   上限（attempts/repair_rounds）与人工控制标签；超限 → 记录
   `budget_exhausted` outcome、打 `blocked` 标签、在 issue 上贴 summary
   评论、退出码 6。
2. **认领后立即烧掉一次 attempt**（写入持久状态）：被中断（甚至 kill -9）
   的运行也已被计数，崩溃循环不可能无限重试；竞争失败的 worker 不计数。
3. **阶段之间**（prepare / execute / verify 前）：检查步数预算、墙钟预算
   和控制标签；超限 → `budget_stop`。
4. **harness 执行期间**：看门狗在 `max_elapsed_seconds_per_run` 到点
   SIGTERM 终止失控 harness。

`budget_stop` 的语义（AC：保留可恢复状态）：

- 先 best-effort 推送任务分支上的部分成果（远程分支即断点续作点）；
- 持久化 `budget_exhausted` outcome（`.agent/runs/task-<key>-*.json` +
  Step Summary）；
- 重新读取计数决定去留：重试预算还有 → 释放认领、`agent-failed` 重新入队；
  预算耗尽 → `blocked` 标签 + `agent-budget.sh summary` 评论（终态，人类
  审查后手工解除）。

## 持久状态：`refs/agent-status/<key>`

与认领协议（`refs/agent-claims/<key>`）同源的 CAS git ref，存单行 JSON：

```json
{"key":"22","task":"issue #22","branch":"agent/issue-22","pr":41,
 "spec_revision":"<获批 spec 的不可变 revision，未从 spec 启动则为空>",
 "phase":"executing","attempts":2,"repair_rounds":1,
 "started_at":1690000000,"updated_at":1690000100,
 "last_failure":"artifact verification failed","control":""}
```

- 覆盖 AC 要求的：spec revision、任务、PR、执行阶段、尝试次数、最近失败。
- 阶段流转：`idle → claimed → preparing → executing → verifying → done`
  （失败 `failed`、预算停止 `budget_exhausted`、控制停止 `paused`/`cancelled`）。
- 任何人在任何 clone 里都能看：`bash scripts/agent-budget.sh show <key>`，
  人类可读汇总：`bash scripts/agent-budget.sh summary <key>`。

## 人工控制：暂停 / 恢复 / 取消

| 动作 | 操作 | 效果 |
|---|---|---|
| 暂停 | 给 issue 加 `agent-paused` 标签 | 新分发拒绝启动（退出码 7）；在飞的运行在下一个阶段门优雅停止：推送部分成果、释放认领、留评论 |
| 恢复 | 移除 `agent-paused` | 下一次分发正常认领，`prepare` 幂等续作已推送的分支 |
| 取消 | 给 issue 加 `agent-cancelled` 标签 | 拒绝启动直到人工清除该标签；outcome 记录 `cancelled` |

标签需在仓库中预先创建（`gh label create agent-paused --color BFD4F2` 等）。

## 通知政策

完成与异常阻塞只用**仓库原生**渠道：issue 评论 / PR / Actions Step
Summary / git ref。不发送 Slack、邮件、webhook 等任何外部通知——除非
项目另行配置并授权（本模板不内置任何此类集成）。
