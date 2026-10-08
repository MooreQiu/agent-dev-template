---
description: 一屏总览：待认领队列、进行中、待审 PR、失败可重试、里程碑进度
allowed-tools: Bash(gh:*)
---

依次执行，然后汇总成一张中文总览表 + 行动建议：

1. **队列**：`gh issue list --label ready-for-agent --state open --json number,title,labels,milestone`（排除已认领/阻塞）
2. **进行中**：`gh issue list --state open --json number,title,assignees,labels` 中有 assignee 的
3. **待审 PR**：`gh pr list --state open --json number,title,author,isDraft`
4. **失败可重试**：`gh issue list --label agent-failed --state open`
5. **里程碑**：`gh api repos/{owner}/{repo}/milestones --jq '.[] | {title, open_issues, closed_issues}'`

输出格式：

- 表格分五节（队列 / 进行中 / 待审 / 失败 / 里程碑），每行含编号、标题、关键标签
- 里程碑行显示进度（closed/total + 百分比）
- 结尾给行动建议：哪些 PR 可 review 合并、哪些失败 issue 需要人看、队列是否需要补 trivial 标签
- 不做任何写操作，只读
