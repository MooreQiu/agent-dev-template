# GitHub App 认证 runbook（去除自动化 PR 审批门）

**为什么需要**：用 `GITHUB_TOKEN` 创建 PR、评论、推送后，这些事件再次触发仓库里的
workflow 时，GitHub 会挂起为 `action_required` 等待人工批准（见 issue #13 引用的
PR Review 运行）。改用 GitHub App 的**短时效 installation token** 后，事件由 App
身份发起，不再触发审批门；token 默认 1 小时过期，泄露面小。

**工作方式**：三个自动化 workflow（`claude.yml`、`agent-sweep.yml`、`pr-review.yml`）
都在 checkout 后执行 `scripts/app-auth.sh`：

- 已配置 App → 生成 RS256 JWT，换取 installation token，写入 `GH_TOKEN`（gh 优先读取），
  并把 git credential helper 指到 `!gh auth git-credential`（token 不落盘）；
- 未配置 App → 明确提示后回退 `GITHUB_TOKEN`（PR 仍可能命中审批门）；
- 两者皆无 → 报错退出。token 值永不出现在 stdout/stderr（runner 上额外注册 `::add-mask::`）。

同时 `claude.yml` 增加了 `scripts/dispatch-filter.sh` 派发门禁：bot（`github-actions[bot]`
或 `<app-slug>[bot]`）发的评论/指派一律拒绝，防止 ack 评论里的 `@claude` 递归触发派发。

## 一次性配置（约 10 分钟）

### 1. 创建 GitHub App

GitHub → Settings → Developer settings → GitHub Apps → **New GitHub App**：

| 字段 | 值 |
|---|---|
| GitHub App name | 任意全站唯一名字（如 `acme-agent-dev-bot`）；bot 登录名用变量配置，不再要求固定名（issue #36） |
| Homepage URL | 仓库地址即可 |
| Expire user authorization tokens | 默认即可 |
| Webhook → Active | **取消勾选**（不需要） |
| Where can this GitHub App be installed | Only on this account（推荐） |

> **为什么 App 名字不再要求固定（issue #36）**：GitHub App 名字占用**全站唯一**命名空间，
> 模板无法预置一个所有部署都能注册的名字（固定名早已被他人占用）。App 的 bot 登录名由
> App 名字生成（slug + `[bot]`），所以请**任选一个全站唯一的名字**创建 App，然后把仓库
> 变量 `AGENT_REVIEWER_BOT_LOGIN` 设为它的 bot 登录名 `<slug>[bot]`（见第 4 步）。
> 自 issue #19 起合并授权来自 `scripts/review-verdict.sh` 的结构化 verdict artifact，
> bot 评论只作展示；`scripts/reviewer-identity.sh` 用该变量解析展示/过滤用的精确
> allowlist（`github-actions[bot]` + 你配置的登录名），变量未设或非法时仅回退
> `github-actions[bot]`，未知 bot 永远不被承认——展示与授权彻底分离，未来任何重新
> 引入评论识别的检查也沿用同一 allowlist。

**Repository permissions（最小集）**：

| 权限 | 级别 | 用途 |
|---|---|---|
| Contents | Read & write | 分支推送、合并 PR |
| Pull requests | Read & write | 建/评/合并 PR |
| Workflows | Read & write | 合并/推送触及 `.github/workflows/*` 的改动（见下方故障模式） |
| Issues | Read & write | 认领、评论、打标签 |
| Metadata | Read-only | 强制自带 |

> **Workflows 权限不能省**：本仓库 agent 的日常产出就包括修改
> `.github/workflows/*`（调 CI、给新 workflow 接线）。App 缺 Workflows 权限时，
> bot 合并任何触及 workflow 文件的 PR 都会被 GitHub 直接拒绝：

```
GraphQL: refusing to allow a GitHub App to create or update workflow
`.github/workflows/agent-sweep.yml` without `workflows` permission
(mergePullRequest)
```

> 不触及 workflow 文件的 PR 仍能正常合并，所以症状是"有的 PR 合得动、有的
> 合不动"，容易被误判成审计没通过——其实是 App 权限问题（见故障排查表）。

App 已创建但漏了这条权限时补授权：GitHub → Settings → Developer settings →
GitHub Apps → 你创建的 App → **Permissions & events** → Repository
permissions → Workflows 设为 Read and write → **Save changes**（改完如安装页
提示重新授权，按提示确认即可）。

不需要 Organization / User permissions。

### 2. 安装到仓库

创建后在 App 页面 **Install App** → 选择本仓库。安装后 URL 里的数字即
installation ID（形如 `https://github.com/settings/installations/12345678`）。

### 3. 生成私钥

App 页面底部 **Private keys → Generate a private key**，下载 `.pem` 文件
（内容形如 `-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----`）。

### 4. 配置仓库 secrets

```bash
gh secret set APP_ID          -b "<App 页面的 App ID，纯数字>"
gh secret set APP_PRIVATE_KEY < ~/Downloads/<app-name>.private-key.pem
# 可选：显式指定 installation ID，跳过每次 API 自动发现
gh secret set APP_INSTALLATION_ID -b "12345678"
```

再配置审计 bot 登录名变量（issue #36：App 名字任选，登录名走变量；把 `<slug>`
换成你的 App 名字的 slug 形式——小写、空格转连字符）：

```bash
gh variable set AGENT_REVIEWER_BOT_LOGIN -b "<slug>[bot]"
# 例：App 叫 acme agent dev bot → gh variable set AGENT_REVIEWER_BOT_LOGIN -b "acme-agent-dev-bot[bot]"
```

不设或设错（大小写、缺 `[bot]` 后缀等）时，`scripts/reviewer-identity.sh` 会
打印警告并仅回退 `github-actions[bot]`；不影响合并授权（自 issue #19 授权只来自
verdict artifact），只影响审计评论的展示/归因过滤。

可选变量（限制谁能让 @claude 派发干活；不设 = 任何人类用户）：

```bash
gh variable set AGENT_ALLOWED_ACTORS -b "你的登录名,同事的登录名"
```

配置完成后无需改任何 YAML——workflow 已接线。

## 端到端 smoke test（验证无审批门）

前提：上述 secrets 已配置。准备一个 `ready-for-agent` 的测试 issue（或任意 issue）。

1. **人类评论触发派发**：用自己的账号在 issue 评论 `@claude 处理这个 issue`。
   - 期望：Claude Dispatch 正常运行；agent 建分支、开 PR。
   - 验证 PR 作者身份是你配置的 `<slug>[bot]`（而非 `github-actions[bot]`）。
2. **PR Review 自动触发、无需批准**：PR 打开后。
   - 期望：PR Review workflow 立即运行（状态不是 `action_required`）。
   - 验证：`gh run list --workflow pr-review.yml --limit 3` 无 approval 待批；
     Actions 页面没有 "Deployment/workflow is waiting for approval"。
3. **ack 评论不递归**：观察 agent 的 "🤖 @claude 收到" 评论发出后。
   - 期望：**不会**再起一个新的 Claude Dispatch run（bot 发言被 filter 拒绝）。
   - 验证：`gh run list --workflow claude.yml --limit 5` 里同一 issue 只有一次派发。
4. **fix push 再次触发 review**：在 PR 上用 `@claude` 请求修改，agent push 新提交。
   - 期望：PR Review 因 `synchronize` 重新运行，同样无需人工批准。
5. **审计合并**：verdict 为 `VERDICT: APPROVE` 时 PR 自动合并、删除分支。
6. **Workflows 权限冒烟**：开一个触及 `.github/workflows/*` 的 PR（agent 的日常
   产出多半就是这类），等审计 `VERDICT: APPROVE` 后由 bot 合并。
   - 期望：合并成功，不再报 `refusing to allow a GitHub App ... without
     `workflows` permission`。
   - 注意：第 1–5 步全过也验证不到这项权限——不触及 workflow 文件的 PR 不需要
     Workflows 授权，本步才覆盖（缺失时的症状即上方故障模式）。

任何一步出现 `action_required`，说明该事件仍是 `GITHUB_TOKEN` 身份发起——检查
对应 workflow 是否漏加 `scripts/app-auth.sh`，或 checkout 是否漏了
`persist-credentials: false`。

## 故障排查

| 现象（app-auth 的明确报错） | 处理 |
|---|---|
| `falling back to GITHUB_TOKEN` | `APP_ID`/`APP_PRIVATE_KEY` secrets 未配置（按上文第 4 步） |
| `installation lookup failed` | App 未安装到本仓库，或用了错误的 API 地址 |
| `failed to sign the JWT` | `APP_PRIVATE_KEY` 不是完整 PEM（复制时丢了换行，直接 `gh secret set < 文件`） |
| `installation token exchange failed` | JWT 时钟偏差或私钥与 App ID 不匹配；重下私钥重配 |
| bot 合并 workflow PR 被拒（`without workflows permission`） | App 缺 Workflows 权限；按第 1 步的补授权路径把 Workflows 设为 Read and write 后重试 |

本地测试（无需网络，API 已 mock）：

```bash
bash tests/test-app-auth.sh          # 认证选择 / 凭证不落日志 / workflow 接线
bash tests/test-dispatch-filter.sh   # bot 递归过滤 / 调用者白名单
bash tests/test-reviewer-identity.sh # 审计 bot 登录名变量 / 回退 / fail-closed
```
