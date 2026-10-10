# Spec Converge：对照已审批规格验收项目完成度并调度剩余工作

issue #21 的落地说明：任务队列排空 ≠ 项目满足 spec。closed issue / merged PR 不能证明整体集成达标，所以收敛阶段把"集成后的目标分支"重新对照已审批的 spec、plan、需求与验收场景评估一遍，把缺口变成可调度的修复任务，全部达标才发布完成状态。入口是 `scripts/spec-converge.sh`，Actions 连接是 `.github/workflows/spec-converge.yml`（workflow_dispatch，人工触发）。findings/evidence/完成记录跨运行持久化与恢复遵循 [docs/SPEC_ARTIFACTS.md](docs/SPEC_ARTIFACTS.md) 的产物契约。

## 流程总览

```
任务队列排空（feature milestone 内无未关闭的非 blocked issue，且 tasks.md 未勾选项都有 issue）
  → workflow_dispatch 触发 spec-converge.yml（输入 spec 路径 + revision + 可选 budget）
  → 共享环境引导（scripts/bootstrap-env.sh：项目配置校验、lockfile 安装、
    钉住的 agent 工具、认证与非交互检查，一律 fail-fast）
  → 预检 implement 角色（scripts/agent-preflight.sh verify implement）
  → --precheck（经 scripts/spec-converge-precheck.sh 适配，见下节）校验队列已排空：
    未排空 → outcome=deferred，跳过 agent 评估、修复调度与完成发布，稍后重跑；
    门禁失败（如审批过期）→ fail closed，作业以原退出码失败
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

## 预检 outcome 与 workflow 控制流（issue #43）

workflow 的预检步骤调用 `scripts/spec-converge-precheck.sh <spec> <revision> --precheck --json`：参数原样转发给入口（`--precheck` 由适配器强制追加，幂等），再把入口退出码映射为显式 outcome 写入 Actions step output（`$GITHUB_OUTPUT`），并始终在 stdout 打印 `outcome=<value>`：

| 入口退出码 | outcome | 适配器退出 | workflow 行为 |
|---|---|---|---|
| 0（队列已排空） | `ready` | 0 | 正常路径：agent 评估 → 验收/调度 → 完成/发布 |
| 3（队列未排空） | `deferred` | 0（附 `::notice::`） | 后续步骤带 `if: steps.precheck.outputs.outcome == 'ready'`，agent 评估、修复 issue 创建与完成发布**整体跳过** |
| 其他（审批过期、用法错误等） | `failed` | 原退出码（附 `::error::`） | fail closed：作业失败，后续步骤不执行 |

把退出码 3 映射成 step exit 0 只会得到一条 notice——步骤成功并不会跳过同 job 的后续步骤，评估与发布照常执行；所以必须由显式 outcome 门控后续步骤。

## findings.jsonl 契约

收敛 agent 把评估结果写到 `specs/<feature>/convergence/findings.jsonl`，每行一个 JSON 对象（字段值不得含双引号或反斜杠）：

```json
{"id": "G001", "requirement": "REQ2", "kind": "missing", "summary": "Signed export is not implemented", "evidence": "src/export has no signing path"}
{"id": "V001", "requirement": "REQ1", "kind": "verified", "summary": "End-to-end export flow exercised; signature verified", "evidence": "specs/016-demo/verification/REQ1-e2e.log"}
```

- `kind`：`missing`（需求未实现）、`regression`（集成后回归）、`verified`（已核验，提供需求→证据追溯）。
- `requirement` 必须逐字引用已审批 spec 里的需求编号（模板支持的 `FR-###`、`SC-###`、`REQ#` 形式均会被识别）。引用了 spec 里不存在的编号 = 超出审批范围：**不会**变成任务，而是 blocked 报告（扩展范围需要重新审批）。
- **verified 行的额外契约（issue #45）**：`summary` 必须写明核验方法与结果；`evidence` 必须是**仓库相对路径且文件真实存在**（提交一份核验日志或引用仓库内既有产物），路径为空、绝对路径、含 `..` 或指向不存在的文件都会被入口 fail-closed 拒绝。
- `id` 在文件内唯一；缺口身份是 `<feature>/<id>`（如 `016-demo/G001`），去重按标题前缀匹配，跨 feature 不冲突。
- 集成验收（`ci-gate.sh run`，即 `.agent/project.json` 配置的 install/build/test/lint/typecheck）失败时会自动合成一条 `integrated-acceptance` 回归缺口，证据指向 `convergence/evidence/gate.json`。

## 收敛预算与 blocked 语义

- 同一缺口的既有 issue 数量（含 closed，按 `[<feature>/<id>]` 前缀统计）记为已用尝试次数；再次发现该缺口且未超预算时创建下一_attempt（标题带 `(attempt N)`），打 `ready-for-agent` 进入调度队列——**修复合并、队列再次排空后重跑收敛**即形成有限循环。
- 尝试次数达到 `--budget` 仍发现该缺口：不再创建修复任务，改为创建（去重的）`blocked` 标签报告 issue，退出码 4。blocked issue 不在调度队列里（sweep 不认领），等待人工决策。
- 超出审批范围的需求同样走 blocked 报告：收敛不会为了"完成"而悄悄改 spec 或实现未审批的需求。
- 只要还有未解决缺口（含 blocked），就绝不发布完成状态、绝不关闭 milestone。

## 完成判定与追溯

只有同时满足才发布 complete：**没有任何缺口**（agent 未发现缺口，且集成验收通过），且**每个已审批需求都有 verified 证据记录**（issue #45）。

- **需求级证据记录**：`complete.json` 的 `requirements` 里每条记录标识需求 id、核验方法与结果（`method`，来自 verified 发现的 summary）、证据位置（`evidence`，真实存在的仓库相对路径）、已审批 spec revision（`revision`）与验证过的代码 commit（`commit`，即验收通过时的 HEAD）。**集成验收通过本身绝不回填未证实的需求**——旧版"回退到 gate.json"的路径已删除：没有 verified 记录的需求会被合成为 `evidence-<REQ>` 修复缺口（已被其他 gap 引用的需求除外，随该 gap 一起修复），回到收敛循环；预算耗尽照常转 blocked。
- **整体验收独立保留**：`complete.json` 顶层的 `acceptance: pass` 与 `evidence: convergence/evidence/gate.json` 记录的是**全项目**集成验收，与需求级证据分开，互不替代。
- 远端可见状态：关闭以 feature 命名的 milestone（`gh api` PATCH），人类在 milestone 视图一眼看到项目完成。
- 全程不改动 spec.md / plan.md / tasks.md / approval.json（测试用 blob 哈希前後对比保证）。

## 与其他 issue 的边界

- 合并判定（issue 关闭是否真的对应 merged PR）属于 #17 调度器的职责；本入口只要求队列排空。
- 被拒绝 PR 的自动修复属于 #20；收敛只负责发现缺口并重新排队。
- 深度调度（依赖排序、p0 阻塞、merge 后即时推进）属于 #17；本入口通过 `ready-for-agent` 标签把修复工作交还既有队列。

## 验收测试

`tests/test-spec-converge.sh`（`npm test` 一并运行）：审批门禁（缺失/过期）、队列排空（milestone 内 open issue、无 issue 的未勾选任务、open 修复工作不重复创建）、closed issue 之外的缺失需求、集成回归（验收失败合成缺口 + 证据）、修复重跑去重（closed attempt 后开新 attempt）、有限预算耗尽转 blocked（含 blocked 报告去重）、超出审批范围转 blocked、绿色集成验收填不了未证实需求（合成 `evidence-<REQ>` 修复缺口 + 重试去重）、全需求证据齐全的真完成（complete.json 记录 method/evidence/revision/commit、整体验收独立保留、关闭 milestone、spec/plan/tasks 不可变）、验收失败压过 verified 发现、findings 契约校验（未知 kind / 重复 id / 未知需求编号 / verified 缺 method 或 evidence / evidence 路径不存在或非法）、非法 budget、预检 outcome 行为（deferred/ready/failed 三态：未排空跳过评估与发布、排空走正常路径、门禁失败 fail closed）、workflow / 角色 / 文档接线。
