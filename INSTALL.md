# INSTALL — 部署手册（写给 agent 执行，人类同样适用）

本文件的目标读者是**编码 agent**：指令必须逐步原样执行，每步有明确的完成判据；不确定时停下来问人，不要跳步、不要改步。

## 前置检查（全部通过才继续）

| 检查 | 命令 | 通过判据 |
|---|---|---|
| gh 已认证 | `gh auth status` | 输出含 `✓ Logged in` |
| git 可用 | `git --version` | 有版本输出 |
| 有 API key | 环境变量 `ANTHROPIC_AUTH_TOKEN` | 非空（智谱/Anthropic 兼容 key） |

## 方式 A：从模板建新仓库

```bash
gh repo create <新仓库名> --template MooreQiu/agent-dev-template --private
gh repo clone MooreQiu/<新仓库名> && cd <新仓库名>
ANTHROPIC_AUTH_TOKEN=$ANTHROPIC_AUTH_TOKEN ./setup.sh --repo=MooreQiu/<新仓库名>
```

完成判据：setup.sh 输出每个 `✓`，无 `✗`。

## 方式 B：部署进已有仓库

```bash
git clone https://github.com/MooreQiu/agent-dev-template /tmp/adt
cd /tmp/adt
./deploy.sh <owner/name>          # 或 ./deploy.sh /path/to/local/repo
```

完成判据：输出出现 `✓ PR 已创建`（或本地模式出现 commit 完成提示），且 `⚠️ 已存在，跳过` 只出现在你确实想保留原文件的地方。

## 必做人工步骤（agent 做不了，提醒人类）

1. **网页开关**：Settings → Actions → General → Workflow permissions → 勾选
   `Allow GitHub Actions to create and approve pull requests`
   （不开则 agent 只能推分支 + 给 compare 链接，PR 需人工点开）
2. **填写项目配置 `.agent/project.json`**：运行时/锁文件与 install/build/test/lint/typecheck 命令必须换成真实值（install 与 test 必填，占位符会被 `scripts/agent-preflight.sh verify-project` 拒绝），AGENTS.md「项目信息」同步为可读摘要

## 部署验证清单（逐项执行，全部满足才算成功）

```bash
gh label list                                  # 含 ready-for-agent、agent-claimed、agent-failed、blocked、trivial
gh secret list -R <owner/name>                 # 含 ANTHROPIC_BASE_URL、ANTHROPIC_AUTH_TOKEN
gh variable list -R <owner/name>               # 含 AGENT_MODEL_DEFAULT、AGENT_MODEL_FLASH（AGENT_EFFORT_DEFAULT 可选）
gh workflow list -R <owner/name>               # Claude Dispatch / Agent Sweep / PR Review 均 active
```

**冒烟测试**（真实闭环）：

```bash
gh issue create -t "Add .gitattributes" -l ready-for-agent -b "## 验收标准
- [ ] 根目录存在 .gitattributes，文本文件统一 LF"
gh issue comment <编号> --body "@claude 请认领并处理，完成后直接提 PR。"
gh run watch <run-id> --exit-status            # 退出码 0
gh pr list                                     # 出现 app/github-actions 创建的 PR
```

## 换 API provider（全部改这两处即可）

| 配置项 | 位置 | 智谱 GLM（默认） | Anthropic 官方 | 其他兼容端点 |
|---|---|---|---|---|
| 端点 | secret `ANTHROPIC_BASE_URL` | `https://open.bigmodel.cn/api/anthropic` | `https://api.anthropic.com` | 供应商文档的 base URL |
| 密钥 | secret `ANTHROPIC_AUTH_TOKEN` | 智谱 key | `sk-ant-...` | 供应商 key |
| 默认模型 | var `AGENT_MODEL_DEFAULT` | `glm-5.3[1m]` | `claude-sonnet-4-6` 等 | 供应商模型名 |
| 快速模型 | var `AGENT_MODEL_FLASH` | `glm-5.3-flash[1m]` | `claude-haiku-4-5` 等 | 供应商模型名 |
| effort 默认（可选） | var `AGENT_EFFORT_DEFAULT` | 留空（CLI 默认） | `high` 等 | 供应商是否生效未知 |

```bash
gh secret set ANTHROPIC_BASE_URL -R <owner/name> -b "<端点>"
gh secret set ANTHROPIC_AUTH_TOKEN -R <owner/name> -b "<key>"
gh variable set AGENT_MODEL_DEFAULT -R <owner/name> -b "<模型>"
gh variable set AGENT_MODEL_FLASH -R <owner/name> -b "<模型>"
# 可选：推理 effort 默认值（low/medium/high/xhigh/max；不设 = CLI 默认）
gh variable set AGENT_EFFORT_DEFAULT -R <owner/name> -b "<effort>"
```

### 模型/effort 优先级与评论覆盖（issue #9）

`@claude` 派发的模型与 effort 由 `scripts/model-config.sh` 按三层优先级解析：**评论覆盖 > 仓库配置（上表 vars）> 文档化兜底**（`glm-5.3[1m]` / `glm-5.3-flash[1m]`；effort 用 CLI 默认）。`trivial` 标签在无覆盖时自动选 flash 档。

评论里可按任务临时指定，选项必须是独立 token：

```text
@claude model=opus effort=high 修复失败的测试
```

- `model`：别名 `sonnet`/`opus` → `AGENT_MODEL_DEFAULT` 档，`haiku` → `AGENT_MODEL_FLASH` 档；或具体模型名（字母数字与 `. _ : / - [ ]`）
- `effort`：`low` / `medium` / `high` / `xhigh` / `max`

非法值（未知别名、含空格/引号/shell 元字符、不在枚举内、同 key 冲突）会被**拒绝**：agent 在 issue/PR 回评具体原因与正确用法，本次派发不启动；修正后重新评论即可。运行日志与确认评论会报告 endpoint（不含密钥）、模型、请求的 effort 及来源；第三方端点的 effort 是否生效标注为 `provider-dependent (unknown)`，不做未生效的承诺。

## 故障排查

| 症状 | 原因 | 处理 |
|---|---|---|
| run 日志 403 "not permitted to create pull requests" | 网页开关未开 | 见「必做人工步骤」第 1 条 |
| run 日志模型调用失败/401 | secrets 配错或 key 无效 | `gh secret list` 核对；本地 `ANTHROPIC_BASE_URL=... ANTHROPIC_AUTH_TOKEN=... claude -p hi` 复测 |
| agent 干完但没开 PR，给了 compare 链接 | 同 403 | 人工点链接开 PR，或开开关后重评论 @claude |
| sweep 没处理某 issue | 有 assignee / 缺 ready-for-agent / 有 blocked | `/queue` 或 `gh issue view` 核对状态 |
| issue 被 claim 后卡住 | run 崩溃/被取消未释放 | 等租约到期由 sweep 的 reconcile 自动回收；急修可 `gh issue edit <n> --remove-label agent-claimed` 手动释放 |
| claude-code-action 报需要 GitHub App | 用了官方 action 分支 | 本模板用 headless CLI，无需 App；确认没改回 anthropics/claude-code-action |
| gh 偶发报 token invalid / 网络错误 | 到 github.com 的连接不稳定 | 重试即可（setup.sh 已内置重试）；必要时给 gh/git 配代理 |
| project-sync 全部 ⚠️ 失败 | 缺 var 或 PAT 无 project 权限 | 核对 `AGENT_PROJECT_NUMBER`、`PROJECT_SYNC_ENABLED`、`GH_PROJECT_TOKEN` |
