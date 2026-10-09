# Spec Advance：已批准特性在管线阶段间的自动推进

issue #47 的落地说明：规划（spec-start）、调度（agent-scheduler）、收敛验收（spec-converge）各自是独立入口，任何环节之后都需要"下一步谁来推进"的确定性答案。入口是 `scripts/spec-advance.sh`——一个由**刚完成阶段的 workflow** 调用的转换协调器，它从持久状态（审批锚点、milestone、队列、在飞 run、项目预算）决定转换，并用**经过认证的 workflow_dispatch** 把管线推进到下一阶段。全链路状态机见 [docs/SPEC_TRACK.md](docs/SPEC_TRACK.md)。

## 流程总览

```
人工审批（approval.json + workflow_dispatch spec-start.yml，唯一常规人工入口）
  → 规划 + issue 生成（spec-start.yml）
  → [after-start] 认证 dispatch agent-scheduler.yml → 调度开跑（无需再触发）
  → agent 实现 → 独立审计 → verified merge / 周期 sweep 恢复
  → scheduler 每次推进（pull_request merged / ready-for-agent / reopened / dispatch）
  → 队列无可选任务时 [on-drained]：对每个已批准且排空的 feature
     认证 dispatch spec-converge.yml（幂等 run key 去重）
  → 收敛验收（spec-converge.yml）
  → [after-converge] 修复 issue 重入队列 → 认证 dispatch 回同一 scheduler（有限循环）
                     完成记录 → 终态；blocked → 可恢复的等人状态
```

## 入口用法与退出码

```bash
scripts/spec-advance.sh after-start <spec-path> <approved-revision> [--json]
scripts/spec-advance.sh after-converge <spec-path> <approved-revision> --verify-status <ok|blocked> [--json]
scripts/spec-advance.sh on-drained [<spec-path>] [--json]
```

| 命令 | 调用方 | 转换 |
|---|---|---|
| `after-start` | spec-start.yml 末尾 | 规划与 issue 生成完成 → dispatch `agent-scheduler.yml`（AC：审批动作之后无需例行人工触发） |
| `after-converge` | spec-converge.yml 末尾（verify 产出 validated status 之后） | 有 `complete.json` → 终态不 dispatch；`--verify-status blocked` → 可恢复等人态不 dispatch；否则修复工作已重入队列 → dispatch `agent-scheduler.yml` |
| `on-drained` | agent-scheduler.yml 的 advance job（无可选任务时）；无参数 = 扫描全部已批准 feature | 排空且通过全部门禁 → dispatch `spec-converge.yml`（`-f spec/-f revision/-f budget`） |

退出码：`0` = 转换已决策（dispatch 或有理由的 skip）；`1` = 门禁失败（fail closed，如 dispatch 失败、审批锚点被破坏、预算文件非法）；`2` = 用法错误。`on-drained` 对单个 feature 的门禁未满足（未排空、有人工控制标签、在飞收敛、审批过期等）按**有理由的 skip** 处理（exit 0，原因进 summary），一个 feature 不就绪不拖垮整个 sweep；意外的 precheck 失败才 fail closed。

## 认证的事件交接（不依赖模型提示）

`GITHUB_TOKEN` 创建的 label/issue 事件不会触发新的 workflow run——所以 `ready-for-agent` 入队本身不是交接。转换通过 `gh workflow run`（workflow_dispatch）完成，这是 GitHub 文档明确的 GITHUB_TOKEN 例外：**用 GITHUB_TOKEN 触发的 workflow_dispatch 会真正启动下游 run**。因此：

- 三个调用方 workflow 都声明 `permissions: actions: write`；
- dispatch 一律优先用 `GITHUB_TOKEN`（`GH_TOKEN="$GITHUB_TOKEN"` 覆盖环境里的 App installation token）——App 安装 token 未必有 actions:write，而调用方 workflow 的 GITHUB_TOKEN 有；
- 测试在 gh 边界断言 dispatch 确实发生、且带上 workflow token（`tests/test-spec-advance.sh`），不假设任何 agent 会"记得去触发"。

## 幂等的 stage/run key 与共享所有权（防重复/乱序事件）

- **stage key = feature + 不可变审批 revision**（与 spec-start/spec-converge/spec-artifacts 的身份锚点一致）。
- **收敛的 run key = `run-name`**：spec-converge.yml 声明 `run-name: spec-converge <spec> @ <revision>`；`on-drained` 用 `gh run list` 匹配同 key 的 `queued`/`in_progress` run，命中即 skip——重复或乱序的排空事件不会叠加收敛运行。已完成是终态：milestone 关闭即 complete（spec-converge 发布完成时关闭），不再收敛。
- **共享所有权**：转换只负责"把队列交回既有 worker"，真正的认领去重仍由统一认领协议（`refs/agent-claims/*` CAS 原子认领 + 租约，见 docs/OPERATIONS.md）与 scheduler 串行基线（concurrency group）承担；`after-start`/`after-converge` 的 scheduler dispatch 无需额外 run key——重复事件收敛到同一选择，第二次运行因认领被持有而自然跳过。

## 每个转换点都尊重的人工控制与预算

- **暂停/取消**：feature milestone 内任何 open issue 带 `agent-paused` / `agent-cancelled` 标签 → 转换 hold（skip，summary 点名控制标签；移除标签后下一次排空事件或手动 dispatch 恢复）。排空门本身也会被暂停的 open issue 阻住（收敛队列门只豁免 `blocked` 报告），双重保险。
- **真阻塞（blocked）**：收敛预算耗尽或需求超出审批范围时 spec-converge 以 exit 4 收场；`after-converge --verify-status blocked` 不启动任何下游运行，只发布可恢复（resumable）状态——人工解决 blocked 报告后，下一次排空事件自动继续。
- **项目预算**：收敛 dispatch 的 `--budget` 取自 `.agent/budgets.json` 的 `max_convergence_rounds`（经 `scripts/agent-budget.sh limit` 读取）；预算文件声明非法时**一律 fail closed**（exit 1，不 dispatch），绝不无界推进。任务级 attempts/repair 预算仍由 agent-task.sh 的认领前检查强制。
- **可恢复状态**：blocked（收敛）、awaiting-approval（审批）、planning 未就绪（跳过并在 summary 报告）都是持久、可文档化恢复的状态；恢复动作只需移除标签/补记录/等下一次事件。

## 仓库原生的阶段 summary

每次转换发布两路输出（AC：summary 带下一步与证据）：

- **Actions Step Summary**（`$GITHUB_STEP_SUMMARY`，人类可读 markdown）：feature、transition、decision、next action、evidence（dispatch 目标、run key、预算、skip 原因）；dispatch 失败不发布 summary（fail closed）。
- **stdout / `--json`**：人类可读行或单 feature 一行的 JSON：
  `{"feature":"016-demo","spec":"specs/016-demo/spec.md","revision":"<sha>","transition":"on-drained","decision":"dispatch|skip|complete|blocked","next":"scheduling|convergence|human-decision|none","dispatched":"<workflow>","reason":"...","budget":N}`

## 与其他 issue 的边界

- 选什么任务（依赖排序、p0 阻塞）属于 #17 的 `agent-schedule.sh`；本入口只在**无可选任务**时探测收敛。
- 收敛本身（findings、修复去重、完成发布）属于 #21 的 `spec-converge.sh`；本入口只触发它并消费其 outcome。
- 跨运行的产物持久化/恢复属于 #44 的 `spec-artifacts.sh`；转换从 durable 状态读取，不复制其契约。
- 被拒 PR 的修复循环属于 #20；修复后的推进由 merge/schedule 事件与本入口共同承担。

## 验收测试

`tests/test-spec-advance.sh`（`npm test` 一并运行）：用法/参数门禁、after-start 的认证 dispatch（workflow token 到达 gh 边界、App token 不出现）、dispatch 失败 fail closed、after-converge 三态（remediation 回调度器 / complete 终态 / blocked 可恢复）、on-drained 的排空 dispatch（带审批 revision 与项目预算）、重复与乱序事件去重（queued/in_progress run key、closed milestone 终态）、未排空/暂停/取消 hold、非法预算 fail closed、planning 未就绪与审批过期的 skip、discovery 扫描恰好推进一个 feature、Step Summary 与 JSON 契约、三个 workflow 的接线与持久化门控不回退、文档链接。
