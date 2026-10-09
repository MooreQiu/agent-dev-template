# 运维指南：队列、认领与裁决（issue #50）

日常无人值守运行时，人类需要回答四个问题：**下一个做什么、为什么是它、
谁在做、结果怎么判**。本文件按这四问组织；运行中的暂停/取消/预算/拒收
恢复见 [RUN_CONTROL.md](RUN_CONTROL.md)，升级与卸载见 [UPGRADE.md](UPGRADE.md)，
安装与冒烟测试见根目录 [INSTALL.md](../INSTALL.md)。

## 里程碑与队列的语义

里程碑和队列是两个正交概念，不要混用：

- **里程碑（milestone）只是交付分组**：它把 issue 组织成 v0.1 这样的交付
  批次，用于看进度；里程碑成员资格**不产生调度资格**，也不会把任务挡在
  队列外。
- **队列的唯一入口是 `ready-for-agent` 标签**。一个 issue 同时满足以下
  条件才可被调度（与 `scripts/agent-schedule.sh` 的实现一致）：
  - open 且带 `ready-for-agent`；
  - 没有 assignee、没有 `agent-claimed` 标签（两者都表示"有人在做了"）；
  - 没有 `blocked` 标签；
  - 没有处于待审状态的开放 PR，也没有已合并并回链的工作（不会重复做）。
- **优先级语义**：任意 `p0` issue 还在队列里时，只调度 `p0`——即使该 p0
  本身被依赖卡住（队列整体等人工解决）；其余按 `p0 < p1 < p2 < p3 < 无
  标签` 排序，同优先级 oldest first。
- 看板命令：`/queue`（本地命令，五段总览）；或只读调度视图
  `bash scripts/agent-schedule.sh list --limit 20`（stderr 解释跳过原因，
  stdout 只有可调度 issue 号）。

## 依赖感知的入队

- 在 issue 正文写一节 `## Dependencies`，用编号引用前置：
  `Depends: #12` 或裸列表 `#12, #13`。
- **前置只有被一个已合并（merged）的 PR 用 `Closes`/`Fixes`/`Resolves`
  回链才算解锁**；issue 仅被关闭、或被 agent 标记完成，都不解锁其下游。
- 调度是**串行**的（一个事件推进一个任务；任务开始前会先拉取最新目标分
  支），因此下游任务不可能先于前置落地启动；合并触发的 scheduler 与
  nightly sweep 都走同一选择逻辑，重复事件被原子认领去重。

## 认领的所有权

- 所有派发路径（`@claude` 评论、assign 指派、nightly sweep、repair）统一
  经过 `scripts/agent-claim.sh` 的**原子认领协议**：对
  `refs/agent-claims/<issue>` 做一次 compare-and-swap 推送，写入执行者
  （owner）与**租约（lease）**，两个 worker 永远拿不到同一任务；输掉
  CAS 竞争的一方收到 denied（退出码 3），本次事件作废。
- 租约默认 **3 小时**（可用环境变量 `AGENT_LEASE_SECONDS` 调整），运行期
  会续约；崩溃/被取消的运行留下的过期租约由 sweep 的 reconcile 自动回收
  （见 [RUN_CONTROL.md](RUN_CONTROL.md#陈旧认领与手动释放)）。
- 自动推进队列的定时事件是 nightly sweep（每天 **19:37 UTC**，单次最多
  处理 3 个 issue，可手动触发并自定义上限）与合并触发的 scheduler；两者
  与评论/指派派发共用同一套选择与认领逻辑。
- issue 的 **assignee 字段是本地会话锁**（`/claim` 工作流），与标签锁是
  两套：人工认领用 assignee，自动派发用 claim ref。两者任一存在，调度器
  都会跳过该 issue。
- 查看单个任务的认领状态：`bash scripts/agent-claim.sh status <issue>`。

## 解读 CI gate 与 review 裁决

`agent/*` 分支的每个 PR 在 **PR Review** workflow 里过两道**相互独立**的
检查：

1. **确定性 CI gate**（`scripts/ci-gate.sh`）：按 `.agent/project.json`
   跑 build/test/lint/typecheck，并对代码改动核对"先失败测试后实现"的
   红→绿证据。gate 失败直接挡住合并。
2. **独立 peer 审计**：一个与作者零共享上下文的第二 agent 复审改动。

判定结果这样读：

- 审计报告是**数据不是权威**：workflow 把它蒸馏成 **verdict artifact**，
  绑定 PR 号、被审的 head SHA、review run 身份与 CI gate 证据摘要；issue
  里以 `VERDICT: APPROVE` / `VERDICT: REQUEST_CHANGES` 开头的评论只是
  显示副本——**机器人评论永远不授权合并**。
- `VERDICT: APPROVE`：merge decider 在合并前对 artifact、gate 证据、
  head 未变化做最后复核，任何缺失/过期/不一致都会 fail-closed（不合并、
  无副作用）；复核通过才 squash merge、删分支、自动关 issue。
- `VERDICT: REQUEST_CHANGES`：PR 被打 `agent-failed`，issue 回队列，进入
  自动修复循环（见 [RUN_CONTROL.md](RUN_CONTROL.md#拒收-pr-的恢复)）。
- **绿的 PR Review run ≠ approval**：它只证明审计跑完了；approval 只来自
  上述被复核的 artifact。拿不准就读审计正文，或自己审了手动合并——任何
  时候都允许。
- **控制路径改动必须人合并**：触及 `.github/workflows/pr-review.yml`、
  `scripts/ci-gate.sh`、`scripts/app-auth.sh`、`scripts/review-verdict.sh`
  的 PR 以 base revision 的控制件审查，并完全跳过自动合并。
