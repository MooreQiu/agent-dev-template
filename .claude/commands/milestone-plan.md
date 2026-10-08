---
description: 把一个目标拆成 milestone + 可认领的 issues
allowed-tools: Bash(gh:*)
---

$ARGUMENTS 是目标描述。依次执行：

1. **澄清**：信息不足以拆解时，最多问 2 个关键问题，然后继续
2. **创建 milestone**：`gh api repos/{owner}/{repo}/milestones -f title="<短名>" -f description="<目标与完成定义>" -f state=open`，记下编号
3. **拆解**：拆成 agent 一次能完成的小任务（每项 ≤ 1 个专注工作日，遵循 INVEST）；每项包含：目标、验收标准（checkbox）、约束；有依赖的在正文注明 "依赖 #x"
4. **建 issue**：`gh issue create --milestone <编号> --label ready-for-agent`，正文按 "🤖 Agent 任务" 模板结构（目标/背景/验收标准/约束）
5. **汇报**：列出 milestone 链接、issue 清单与依赖顺序；说明三种触发方式：`/claim <n>` 手动、@claude 评论、等 agent-sweep
