# SPEC_ARTIFACTS — 跨运行的规划与收敛产物契约（issue #44）

Spec Start 与 Spec Converge 在各自 workflow 里上传产物，但后来的全新 runner
只做本地检出，从不取回：规划与收敛只能被静默重算。本文是唯一的权威契约
（single authoritative contract），规定 plan.md、tasks.md、findings、完成记录
（complete.json）与引用的验证 evidence 如何跨运行持久化与恢复。

## 角色

- `scripts/spec-artifacts.sh manifest`：把负载文件绑定成一份带版本的
  manifest.json（feature 身份 + 已审批 spec revision + 验证过的 target
  commit + 每个文件的 sha256），workflow 与 manifest 一起上传。
- `scripts/spec-artifacts.sh restore`：全新 runner 用 gh REST API
  （`actions: read`）按 key 检索最新 artifact，校验全部绑定与哈希后把负载
  拷回当前检出，从上次中断处继续而不是重算。

## 检索 key 与 newest-wins

- key：`spec-planning-<feature>-<revision>`（规划：plan.md/tasks.md）与
  `spec-convergence-<feature>-<revision>`（收敛：findings.jsonl、evidence、
  complete.json）。
- 重复上传是常态（每次重跑都会上传）：同一 key 取**最新**（created_at 降序，
  再按 artifact id 降序打破平局）的非过期 artifact，确定性检索、绝无歧义。
- 束结构：bundle 根 = 规划 `specs/<feature>/`、收敛
  `specs/<feature>/convergence/`，含 manifest.json 与按根相对布局的负载。

## 绑定与拒绝（fail-closed）

restore 逐项校验：kind/feature/spec 路径/revision 必须完全一致；spec_blob
必须等于已审批 revision 中该 spec 的 blob（防止同 revision 下内容漂移）；
收敛束还必须匹配 `--target`（当前 HEAD）。任一不符即拒绝；哈希不匹配视为
损坏；束内出现清单未列文件或清单重复条目视为歧义，一律拒绝。清单校验全部
通过之前不写任何文件，被拒绝的束不留半成品状态。

**已审批 spec（spec.md）与审批记录（approval.json）绝不进入 artifact**，
restore 也绝不覆写它们——git 是它们唯一的存储。manifest 把
`specs/<feature>/spec.md` 与 `specs/<feature>/approval.json` 列为受保护
路径。

退出码：`0` 成功；`1` 拒绝（不匹配/损坏/歧义/受保护）；`2` 用法错误；
`3` 找不到 artifact（从未上传、被删或已过期），规划工作流把它映射为"全新
规划"而非失败；`4` stale——束绑定的 target 与当前 `--target` 不一致，
收敛必须重新评估而不是静默复用旧结论。

## Workflow 接线

- spec-start.yml：`actions: read`；校验 spec 之前先 `restore planning`，
  exit 3 → 全新规划、exit 1/4 → fail-closed；上传前先 `manifest planning`；
  artifact 名 `spec-planning-${{ env.FEATURE }}-${{ inputs.revision }}`，
  路径块只含 manifest.json/plan.md/tasks.md（不含 spec.md）。
- spec-converge.yml：`actions: read`；precheck ready 之后
  `restore convergence --target "$(git rev-parse HEAD)"`，exit 3/4 → 重新
  评估（`outcome=evaluate`）、exit 0 → 跳过 agent 评估直接复核
  （`outcome=restored`）、exit 1 → fail-closed；上传前
  `manifest convergence --target "$(git rev-parse HEAD)"`，artifact 名
  `spec-convergence-${{ env.FEATURE }}-${{ inputs.revision }}`。

## 保留（retention）与恢复（recovery）的限制

- GitHub Actions artifact 默认保留 90 天，之后自动过期删除；删除仓库或
  手动删除同理。过期即不可恢复，restore 报 exit 3，唯一出路是重跑对应
  workflow 重新生成（planning 重规划、convergence 重评估）。
- artifact 有大小上限（单束压缩后约 10 GB，evidence 应只存小型验证产物，
  不要塞构建产物或日志全文）。
- 恢复只还原 bundle 里的负载文件；不还原 git 历史、PR/issue 状态或审批
  记录。若 plan/tasks/findings 需要长期留存，把它们提交进 git 是显式的
  人工决定，本契约不做自动提交。
