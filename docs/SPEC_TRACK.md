# Spec Track：从已审批 spec 到验证完成的全流程追踪

issue #24（tracking issue）的落地说明：自主流水线由多个独立入口组成（审批、规划、调度、实现、审计合并、收敛验收），任何时刻都需要回答三个问题——现在走到哪一步、下一步谁能推进（agent 还是人）、为什么停了。入口是 `scripts/spec-track.sh`，Actions 连接是 `.github/workflows/spec-track.yml`（workflow_dispatch，人工触发，状态写入 run summary）。

**只读保证**：追踪器绝不创建、修改或关闭任何 issue/PR/文件，远程访问仅限 `gh issue list` 与里程碑状态查询。重复运行输出完全一致，因此它自己不可能造成重复工作（issue #24 验收第 3 条的追踪侧切片）；排空子任务、批量入队等动作仍由各自入口负责——追踪器绝不代替人把 children 一次性入队。

## 状态机

```
（无/无效/过期 approval.json）        awaiting-approval   等人：审批或重新审批
      ↓ 人工审批（唯一常规人工入口）
缺 plan.md / tasks.md                 planning            自主：spec-start 规划（specify 角色）
      ↓ /speckit-plan、/speckit-tasks
未勾选任务尚无 issue                  scheduling          自主：scripts/spec-start.sh 生成 issue
      ↓ ready-for-agent 入队
milestone 内有 open 非 blocked issue  in-progress         自主：agent-sweep 认领并 TDD
      ↓ 队列排空（含收敛修复 issue 重入队列的有限循环）
无完成记录 / 记录被拒                 converging          自主：spec-converge 验收（findings→修复任务）
      ↓ complete.json 且证据齐全
仅剩 open blocked 报告                blocked             等人：预算耗尽/范围外/真未解决，可恢复
                                      complete            终态：需求级 + 集成证据齐全
```

判定顺序（与 spec-converge 的队列语义一致）：先看 open 非 blocked issue（有 → in-progress），再看仅剩 blocked 报告（→ blocked），再看未调度任务（→ scheduling），最后验收完成记录。

## 输出契约

```bash
scripts/spec-track.sh specs/<feature>/spec.md [--json]
```

- `--json`：stdout 单行 JSON（调度器/工作流消费），人类可读摘要走 stdout（无 `--json` 时）、诊断日志走 stderr。
- 字段：`status`（上表状态名）、`autonomous`（true=下一步无需人）、`next`（`approve|plan|generate-issues|sweep|converge|human-decision|none`）、任务与队列计数、`requirements_total/requirements_evidenced`、`milestone`、`warnings[]`（机器安全，不含 issue 标题等不可控文本）。
- 退出码：`0` 状态已计算（可自主推进或已完成）；`1` 门禁失败（spec 缺失、approval 记录里的 revision 无法解析等）；`2` 用法错误；`4` **waiting-on-human**——awaiting-approval 或 blocked。workflow 把 4 映射为 `::notice::`，不是失败。
- approval.json 缺失/缺 approver/spec 被改动（stale）都归为 awaiting-approval（exit 4）而非报错：审批门是正常入口状态，日志会给出具体原因（改 spec 必须重新审批，绝不静默放行）。

## blocked 的证据与可恢复性 / resumable blocked state（issue #24 验收第 5 条）

blocked 状态的证据就是 durable 工件本身：stderr 逐条列出 blocked issue（编号 + 标题前缀 `[<feature>/<id>]`），JSON 给出 `blocked_issues` 计数；预算耗尽的原因、findings 引用都在 blocked issue 正文里（见 docs/SPEC_CONVERGE.md）。**可恢复**：人解决并关闭 blocked issue 后，下一次追踪自动回到 converging（autonomous=true）——测试覆盖该转移。approval 侧同理：人补审批记录后链条从 planning 继续。

## 完成判定的证据校验（issue #24 验收第 6 条）

只有当 `specs/<feature>/convergence/complete.json` 同时满足才报 complete：

- 顶层 `status` 为 `complete` 且 `acceptance` 为 `pass`（集成证据）；
- 已审批 spec 中识别出的**每个**需求编号（`FR-###`/`SC-###`/`REQ#`，与 spec-converge 同一识别器）在 `requirements` 里有一条**非空** evidence（需求级证据），缺一条即拒绝。

记录被拒（缺需求、空证据、acceptance 非 pass）→ 状态回落 converging，`warnings` 点名缺失项，next=converge（重跑收敛）。里程碑仍 open 只是 advisory warning，不否定本地记录（spec-converge 关里程碑本就是 best-effort）。

## 与其他 issue 的边界

- 深度调度（依赖排序、p0 阻塞、merge 后即时推进）属于 #17；追踪器只报 next action。
- 被拒 PR 的修复循环属于 #20；追踪器把 open 修复 issue 视作普通 in-progress（`[<feature>/<G###>]` 修复任务重入队列即自主推进，issue #24 验收第 2/4 条的追踪侧切片）。
- 运行预算的强制与持久进度记录属于 #22；追踪器是无状态聚合器，不写任何运行记录。
- 合并判定、防重复事件/防未审合并属于 #18/#19；追踪器只读，不参与合并决策。

## 验收测试

`tests/test-spec-track.sh`（`npm test` 一并运行）：用法/输入门禁、审批门（缺失/无 approver/stale → awaiting-approval，且不访问远程）、AC1 链路走查（planning→scheduling→in-progress→converging→complete，审批后每一步 autonomous=true）、修复 issue 开着时仍 in-progress（next=sweep）、追踪只读且重复运行输出一致、blocked 显式且列出证据 issue、关闭 blocked 后恢复 converging、完成记录校验（缺需求/空证据/acceptance fail → 拒绝，齐全 → complete）、里程碑 open 仅 warning、JSON 单行契约、workflow/文档接线与 gh 只读访问。
