# 升级、冲突、回滚与卸载（issue #50）

模板没有自动升级器、也没有自动卸载器——这两件事**按设计是人工步骤**，
本文件把它们写成可照做的清单。首次安装见 [INSTALL.md](../INSTALL.md)；
分发包的构建与内容契约见 [BUNDLE.md](BUNDLE.md)。

## 版本升级

升级 = 用新版模板重跑一次部署。两条等价路径：

**路径 A：从模板仓库部署（推荐）**

```bash
git clone https://github.com/MooreQiu/agent-dev-template /tmp/adt && cd /tmp/adt
./deploy.sh <owner/name>
```

**路径 B：从版本化分发包部署（可审计/离线）**

```bash
tar -xzf agent-dev-template-<版本>.tar.gz
cd agent-dev-template-<版本>
./deploy.sh /path/to/your-repo
```

包的来源与校验（manifest、SHA-256）见 [BUNDLE.md](BUNDLE.md)；发布包由
`scripts/build-bundle.sh` 构建，内容取自不可变的 commit revision。

**升级的真实语义是"补新增"，不是"覆盖更新"**：`deploy.sh` 对已存在的
文件一律 skip（保留你的版本），只新增目标缺失的文件。因此升级后：

- 模板新增的组件会自动补上；
- 你本地改过的组件**原地不动**，不会自动吸收模板的新改动——结尾的
  "⚠️ 部署不完整"清单列出了全部被跳过的组件，需逐个与上游
  `diff -u <你的文件> /tmp/adt/<文件>` 手动比对合并。这一步是手动的，
  当前没有自动 diff/合并工具。

## 冲突处理

动手前先预览，不产生任何修改：

```bash
./deploy.sh --preview /path/to/your-repo
```

三种标记的含义：

| 标记 | 含义 | 实际部署时 |
|---|---|---|
| `+` | 目标缺失 | 新增 |
| `=` | 与模板完全一致 | 无变化 |
| `!` | 已存在且与模板不同（本地定制） | **保留本地版本，绝不覆盖** |

`!` 标记就是你的定制清单。想让某个定制文件吸收模板更新：在模板副本里
`diff -u` 两个版本，人工合并后提交——模板永远不会替你做这个决定。

## 回滚（rollback）

按部署方式选择：

- **remote 模式（默认）**：部署物落在 `chore/agent-dev-template` 分支并
  开 PR。合并前回滚 = 直接关闭该 PR；合并后回滚 = `git revert` 那个
  merge/squash commit。
- **local 模式**：文件已 commit 到本地 `chore/agent-dev-template` 但未
  push，回滚 = `git checkout <原分支> && git branch -D chore/agent-dev-template`。
- **在线配置的回滚**：`setup.sh` 写入的 labels/secrets/vars/分支保护需
  手动恢复，命令见下方"卸载"；分支保护规则若被改动，按改动前的截图/记
  录在 Settings 中手工复原。

## 卸载（removal）

无自动卸载器，按清单手动执行；模板对仓库外**没有任何依赖**（无外部服
务、无 webhook），删完即干净。

1. **停用并删除 workflow**（`gh workflow disable` 或直接删文件）：
   deploy 路线带来 6 个——`ci.yml`、`claude.yml`、`agent-sweep.yml`、
   `pr-review.yml`、`review-watchdog.yml`、`project-sync.yml`；从模板新建的仓库还有全部
   `.github/workflows/`（agent-scheduler.yml、spec-*.yml 等）。
2. **删除体系文件**：deploy 路线是 ITEMS 清单里的 20 项（`AGENTS.md`、
   `CLAUDE.md`、`INSTALL.md`、`.agent/`、`docs/`、`scripts/`、`.specify/`、
   `.claude/commands/`、`.claude/skills/`、`.github/ISSUE_TEMPLATE/`、
   `.github/PULL_REQUEST_TEMPLATE.md`、上述 6 个 workflow、`package.json`、
   `package-lock.json`、`setup.sh`）；
   模板路线另加 `.codex/`。
3. **删除 labels**：

```bash
for l in ready-for-agent agent-claimed agent-failed blocked trivial p0 p1 p2 p3; do
  gh label delete "$l" --yes
done
```

4. **删除 secrets 与 variables**（凭证随仓库删除，不留在任何别处）：

```bash
gh secret remove ANTHROPIC_BASE_URL
gh secret remove ANTHROPIC_AUTH_TOKEN
gh variable delete AGENT_MODEL_DEFAULT
gh variable delete AGENT_MODEL_FLASH
# 可选存在时一并删除：AGENT_EFFORT_DEFAULT、AGENT_HARNESSES、
# AGENT_MODEL_CODEX/GEMINI/OPENCODE、AGENT_ALLOWED_ACTORS、
# AGENT_PROJECT_NUMBER、PROJECT_SYNC_ENABLED 及对应 harness 的 key secret
```

5. 关闭已启用的 auto-merge（Settings → Actions）与可选的 Projects board。

## 保留的用户定制

卸载/升级天然保留的东西：

- **你的项目本身**：源代码、`README`、`LICENSE`、`.gitignore` 等——
  `deploy.sh` 的 ITEMS 刻意不包含它们；
- **`.agent/project.json`**：deploy/模板路线都携带一份默认 npm 配置，其中
  运行时/构建/测试命令是给消费者替换的起点（INSTALL.md 必做人工步骤）；
  你已定制的版本部署时一律不覆盖；
- 所有 `!` 冲突文件（见上）；认领/状态 ref（`refs/agent-claims/*`、
  `refs/agent-status/*`）随 git 仓库保留，卸载 workflow 后不再有人读写。

## 密钥（secrets）的处理

- 凭证只存 GitHub secrets：`ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`
  （多 harness 另有 `CODEX_API_KEY` / `GEMINI_API_KEY` 等）；运行日志只
  报告 endpoint，永不回显密钥。
- **轮换（rotation）**：`gh secret set ANTHROPIC_AUTH_TOKEN -R <owner/name>`
  原地覆盖即可生效，无需改代码、无需重启任何东西；建议定期轮换，疑似泄
  露立即轮换。
- 执行 `setup.sh`/`deploy.sh` 时用的环境变量 `ANTHROPIC_AUTH_TOKEN` 只被
  写入 secrets，不落盘、不进 commit。
- 分发包层面：`build-bundle.sh` 的白名单 + deny list 双防线保证
  `.env`、`*.pem`、`*.key` 等凭证文件**永远不进包**（见
  [BUNDLE.md](BUNDLE.md)）。
- 卸载时 secrets 一并删除（见上），模型供应商侧的 key 由你在供应商控制
  台吊销。
