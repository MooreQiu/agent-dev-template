# Spec Converge：对照已审批规格验收项目完成度并调度剩余工作

issue #21 的落地说明：任务队列排空 ≠ 项目满足 spec。closed issue / merged PR 不能证明整体集成达标，所以收敛阶段把"集成后的目标分支"重新对照已审批的 spec、plan、需求与验收场景评估一遍，把缺口变成可调度的修复任务，全部达标才发布完成状态。入口是 `scripts/spec-converge.sh`，Actions 连接是 `.github/workflows/spec-converge.yml`（workflow_dispatch，人工触发）。

## 流程总览

```
任务队列排空（feature milestone 内无未关闭的非 blocked issue，且 tasks.md 未勾选项都有 issue）
  → workflow_dispatch 触发 spec-converge.yml（输入 spec 路径 + revision + 可选 budget）
  → 预检 implement 角色（scripts/agent-preflight.sh verify implement）
  → --precheck 校验队列已排空，未排空则以 notice 结束，稍后重跑
  → 收敛 agent 以 implement 角色显式调用 /speckit-converge，对集成目标分支
    做 spec/plan/需求/验收场景评估，产出 findings.jsonl
  → scripts/spec-converge.sh 跑配置的集成验收（复用 scripts/ci-gate.sh run）
  → 缺口（agent 发现 + 验收失败自动合成的回归缺口）去重后转成修复 issue（ready-for-agent，恢复调度）
  → 预算耗尽 / 超出审批范围的需求 → blocked 报告，绝不谎报完成
  → 无缺口且验收通过 → 写完成记录（需求 → 证据）并关闭 feature milestone
```

审批门禁与 spec-start 完全一致：`specs/<feature>/approval.json` 的不可变 revision 锚点、工作区 spec 必须与审批 blob 一致（防 stale）、必须存在 plan.md / tasks.md。收敛阶段**绝不修改** spec.md、approval.json、plan.md、tasks.md——已审批内容是只读锚点。

## 入口用法

```bash
scripts/spec-converge.sh specs/<feature>/spec.md <approved-revision> [options]
```

| 选项 | 含义 |
|---|---|
| `--findings FILE` | 收敛 agent 的发现（JSON Lines，见下）；缺口变修复任务，verified 变需求→证据追溯 |
| `--budget N` | 每个缺口最多修复尝试次数（默认 2），即有限收敛预算 |
| `--precheck` | 只做门禁 + 队列排空检查（workflow 用它避免在未排空时浪费 agent 运行） |
| `--dry-run` | 只校验门禁与 findings 契约，不访问 gh、不跑验收 |
| `--json` | stdout 输出单行 JSON 摘要，人类可读日志走 stderr |

退出码：`0` 成功（complete 或 remediation-scheduled）；`1` 门禁/输入失败；`2` 用法错误；`3` 队列未排空（稍后重试，不是错误）；`4` blocked——有需求在预算内无法收敛或超出审批范围，需要人工决策。

## findings.jsonl 契约

收敛 agent 把评估结果写到 `specs/<feature>/convergence/findings.jsonl`，每行一个 JSON 对象（字段值不得含双引号或反斜杠）：

```json
{"id": "G001", "requirement": "REQ2", "kind": "missing", "summary": "Signed export is not implemented", "evidence": "src/export has no signing path"}
{"id": "V001", "requirement": "REQ1", "kind": "verified", "summary": "End-to-end flow checked", "evidence": "npm test green on target branch"}
```

- `kind`：`missing`（需求未实现）、`regression`（集成后回归）、`verified`（已核验，提供需求→证据追溯）。
- `requirement` 必须逐字引用已审批 spec 里的需求编号（模板支持的 `FR-###`、`SC-###`、`REQ#` 形式均会被识别）。引用了 spec 里不存在的编号 = 超出审批范围：**不会**变成任务，而是 blocked 报告（扩展范围需要重新审批）。
- `id` 在文件内唯一；缺口身份是 `<feature>/<id>`（如 `016-demo/G001`），去重按标题前缀匹配，跨 feature 不冲突。
- 集成验收（`ci-gate.sh run`，即 `.agent/project.json` 配置的 install/build/test/lint/typecheck）失败时会自动合成一条 `integrated-acceptance` 回归缺口，证据指向 `convergence/evidence/gate.json`。

## 收敛预算与 blocked 语义

- 同一缺口的既有 issue 数量（含 closed，按 `[<feature>/<id>]` 前缀统计）记为已用尝试次数；再次发现该缺口且未超预算时创建下一_attempt（标题带 `(attempt N)`），打 `ready-for-agent` 进入调度队列——**修复合并、队列再次排空后重跑收敛**即形成有限循环。
- 尝试次数达到 `--budget` 仍发现该缺口：不再创建修复任务，改为创建（去重的）`blocked` 标签报告 issue，退出码 4。blocked issue 不在调度队列里（sweep 不认领），等待人工决策。
- 超出审批范围的需求同样走 blocked 报告：收敛不会为了"完成"而悄悄改 spec 或实现未审批的需求。
- 只要还有未解决缺口（含 blocked），就绝不发布完成状态、绝不关闭 milestone。

## 完成判定与追溯

只有同时满足才发布 complete：**没有任何缺口**（agent 未发现缺口，且集成验收通过）。

- 本地完成记录：`specs/<feature>/convergence/complete.json`，其中 `requirements` 列出 spec 中每个需求编号及证据——verified 发现引用 agent 证据，其余回退到集成验收证据（`convergence/evidence/gate.json`）。证据目录已加入 `.gitignore`，不污染工作区。
- 远端可见状态：关闭以 feature 命名的 milestone（`gh api` PATCH），人类在 milestone 视图一眼看到项目完成。
- 全程不改动 spec.md / plan.md / tasks.md / approval.json（测试用 blob 哈希前後对比保证）。

## 与其他 issue 的边界

- 合并判定（issue 关闭是否真的对应 merged PR）属于 #17 调度器的职责；本入口只要求队列排空。
- 被拒绝 PR 的自动修复属于 #20；收敛只负责发现缺口并重新排队。
- 深度调度（依赖排序、p0 阻塞、merge 后即时推进）属于 #17；本入口通过 `ready-for-agent` 标签把修复工作交还既有队列。

## 验收测试

`tests/test-spec-converge.sh`（`npm test` 一并运行）：审批门禁（缺失/过期）、队列排空（milestone 内 open issue、无 issue 的未勾选任务、open 修复工作不重复创建）、closed issue 之外的缺失需求、集成回归（验收失败合成缺口 + 证据）、修复重跑去重（closed attempt 后开新 attempt）、有限预算耗尽转 blocked（含 blocked 报告去重）、超出审批范围转 blocked、真完成（complete.json 需求→证据追溯、关闭 milestone、spec/plan/tasks 不可变）、验收失败压过 verified 发现、findings 契约校验（未知 kind / 重复 id / 未知需求编号）、非法 budget、workflow / 角色 / 文档接线。
