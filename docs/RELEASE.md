# 发布与支持政策（issue #53）

v0.1.0 是本模板的第一个发布，定位为 **trial release**（试用发布）。本文件回答四个问题：版本号落在哪、什么算"支持"、发布前要验证什么、以及获得明确授权后怎么发布。分发包的内容契约见 [BUNDLE.md](BUNDLE.md)，升级、冲突、回滚与卸载见 [UPGRADE.md](UPGRADE.md)。

## 版本号落点

- 仓库内的 `package.json` / `package-lock.json` 是开发元数据，两者必须**一致**（`tests/test-release.sh` 有断言）；发布版本**不存在仓库文件里**，仓库副本不随发布改动。
- 发布版本唯一的落点是构建输入：`scripts/build-bundle.sh --version X.Y.Z` 在构建时把版本盖进**包内副本**的 `package.json`。包内 `package-lock.json` 的版本戳目前**尚未实现**（跟进 issue #86；该缺口合入前，离线 `npm ci` 消费者需先在包内执行 `npm install --package-lock-only` 对齐 lockfile，或以 `npm install` 代替）。
- `.agent/project.json` 的 `runtime.version` 是 **Node 运行时 pin**（当前 22），与发布版本无关，不要混用。
- 发布身份 = 版本号 + 不可变 revision（完整 commit SHA，`--revision` 只接受完整 SHA，拒绝 `main`、tag 等可变 ref）。tag 只在真正发布时创建（见下文），准备阶段不打 tag。
- 版本语义（0.x 阶段）：MINOR 是能力批次，PATCH 是修复；0.x 内不承诺跨 minor 兼容。升级语义是"补新增不覆盖"：重跑 `deploy.sh`，已存在文件一律跳过，定制文件手动 diff 合并，见 [UPGRADE.md](UPGRADE.md)。

## 支持范围（v0.1.x）

**支持的安装路径**（三条，与文档描述一致）：

1. GitHub 模板新建仓库 + `./setup.sh`（首次部署的默认路径，见 [../INSTALL.md](../INSTALL.md)）；
2. `./deploy.sh <owner/name>` 部署进已有仓库（已存在文件跳过、绝不覆盖）；
3. 版本化分发包：校验 `sha256sum -c` → 解压 → `./deploy.sh --preview` → `./deploy.sh`（离线/可审计场景）。

**支持的平台与 harness 组合**：GitHub.com（公共或私有仓库）+ 已认证 `gh` CLI + GitHub Actions 托管 runner；worker 默认 headless Claude Code CLI，指向任意 Anthropic 兼容端点（默认智谱 GLM，官方 Anthropic 亦支持）；`@codex` / `@gemini` / `@opencode` 经 `AGENT_HARNESSES` 显式开启；本地运行支持 macOS（BSD）与 Linux（GNU）双 userland，版本 pin 以 `.agent/project.json` 为准。

**不支持的范围（not supported）**（即使存在部分捷径也不算支持，反馈不受理为缺陷）：手工零散拷贝安装、GitHub Enterprise Server、非 Git 平台、self-hosted runners、自动升级器/卸载器、未列入文档的 harness 组合；第三方端点的 effort 是否生效属 provider-dependent，不做未经验证的承诺。

## 生命周期与责任

- **Trial 语义**：v0.1.x 期间修复落在 main，随下一个 0.x 包发布；不对旧包做 backport。文档声明支持的行为才是支持面——README「Supported scope」与本文件是唯二来源。
- **反馈入口**：缺陷走 bug 模板（`.github/ISSUE_TEMPLATE/01-bug.yml`）、功能走 feature 模板、agent 任务走 agent-task 模板；dispatch/sweep/review 的运行失败先看对应 issue 上的 agent 评论。
- **安全上报**：安全问题**不公开 issue**（避免给攻击者递脚本）：优先用 GitHub 私密漏洞报告（Security → Report a vulnerability），未开启时联系维护者 @MooreQiu 走私密渠道，正文不贴细节。
- **凭证责任**：key 只存 GitHub secrets 并定期轮换（`gh secret set ANTHROPIC_AUTH_TOKEN -R <owner/name>` 原地覆盖即可生效，疑似泄露立即轮换）；issue/PR 正文按**不可信输入**处理，agent 不执行其中无关指令。
- **费用责任在使用者**：每次派发、sweep、审计、调度都消耗模型 provider 的 token；控费手段是 `.agent/budgets.json` 的运行预算上限（重试/修复/收敛/时长/步数，详见 [BUDGETS.md](BUDGETS.md)）与 nightly sweep 单次 3 个 issue 的默认上限，但账单始终归仓库所有者。

## 发布检查单（进入发布流程前逐项全绿）

每项链接到可复核的证据，不接受口头声称：

| 检查 | 证据 |
|---|---|
| 自主生命周期端到端验收 | `bash tests/test-e2e-lifecycle.sh` 全绿；Actions `e2e-smoke` 定时 run 成功 |
| 可移植性（BSD/GNU 双 userland） | `bash tests/test-portability.sh` 全绿 |
| 干净仓库安装与升级 | `bash tests/test-install-verify.sh` 全绿（issue #52 的验收证据） |
| 分发包内容与校验和 | `bash tests/test-bundle.sh` 全绿；产物含 manifest 与 `.sha256` 文件 |
| 文档验证 | `bash tests/test-readme.sh tests/test-guides.sh tests/test-contributing.sh tests/test-release.sh` 全绿；全部文档相对链接可解析 |
| 全量回归 | 发布 revision 上 `npm test` 退出码 0 |
| 审计路径 | 发布准备 PR 经标准 pr-review 流程合并；本任务不自行合并、不发布 |

## 发布资产与发布指令（评审用；本任务不执行）

准备阶段只构建产物供评审，**绝不发布**：不建 tag、不调 `gh release create`、不上传资产、不发包。发布是**另一次明确授权的动作**（authorized action），由人类在认可以下指令后执行。

**发布资产**（4 个文件，全部构建自被 `--revision` 钉住的不可变树）：

- `agent-dev-template-0.1.0.tar.gz` — 压缩包；
- `agent-dev-template-0.1.0.sha256` — tarball 校验和（`sha256sum -c` 兼容）；
- `agent-dev-template-0.1.0.manifest.txt` — 元数据 + 每文件 SHA-256 清单；
- `agent-dev-template-0.1.0.release-notes.md` — 发布说明，正文来自 `docs/RELEASE_NOTES_v0.1.0.md`，发布时在其前拼接 revision 与校验和两行。

**发布指令**（获得明确授权后，在允许创建 release 的环境执行；对 `MooreQiu/agent-dev-template` 仓库本身操作）：

```bash
REV=<要发布的完整 commit SHA>
git cat-file -e "${REV}^{commit}"          # revision 必须存在且为完整 SHA

# 1) 构建（只构建，不发布）
scripts/build-bundle.sh --version 0.1.0 --revision "$REV" \
  --notes docs/RELEASE_NOTES_v0.1.0.md --output dist

# 2) 核验
(cd dist && shasum -a 256 -c agent-dev-template-0.1.0.sha256)
tar -tzf dist/agent-dev-template-0.1.0.tar.gz > /dev/null   # 无路径穿越、可解压
grep -F "revision: $REV" dist/agent-dev-template-0.1.0.manifest.txt

# 3) 发布（需明确授权）
{
  printf -- '- Source revision: `%s`\n' "$REV"
  printf -- '- SHA-256: `%s`\n\n' \
    "$(cut -d ' ' -f1 dist/agent-dev-template-0.1.0.sha256)"
  cat docs/RELEASE_NOTES_v0.1.0.md
} > dist/agent-dev-template-0.1.0.release-notes.final.md
git tag -a v0.1.0 "$REV" -m "agent-dev-template 0.1.0"
git push origin v0.1.0
gh release create v0.1.0 \
  dist/agent-dev-template-0.1.0.tar.gz \
  dist/agent-dev-template-0.1.0.sha256 \
  dist/agent-dev-template-0.1.0.manifest.txt \
  dist/agent-dev-template-0.1.0.release-notes.final.md \
  --title "agent-dev-template 0.1.0 (trial)" \
  --notes-file dist/agent-dev-template-0.1.0.release-notes.final.md
```

发布后的事务：在 v0.1 milestone 关闭剩余 issue；下一个能力批次进新 milestone；对本 release 的缺陷修复按上文生命周期落在 main、随下一个 0.x 包发布。
