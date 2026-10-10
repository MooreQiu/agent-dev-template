# Bundle：版本化分发包的构建与内容契约

issue #51 的落地说明：模板既支持 GitHub Template（新项目），也需要一份**可审计的版本化 Release 包**（已有项目/离线分发/供应链核对）。入口是 `scripts/build-bundle.sh`，内容契约是 `scripts/bundle-allowlist.txt`；本文件回答两个问题——包里有什么、为什么有些东西永远不进包。

## 用法

```bash
scripts/build-bundle.sh --version 0.1.0 [--revision <完整commit SHA>] \
  [--source <仓库目录>] [--output <目录>] [--notes <发布说明文件>]
```

- `--version` 必填（`X.Y.Z`，容许前缀 `v`）；构建时会把版本号盖进包内 `package.json` 的 `version` 字段，并同步盖进包内 `package-lock.json` 的两处根 `version` 字段（依赖 pin 不受影响；只改包内副本，不动仓库文件）。
- `--revision` 是**不可变源版本**：只接受完整 commit SHA（40/64 位十六进制），拒绝 `main`、tag 等可变 ref；缺省取 `--source`（默认本仓库）的 `HEAD` 解析结果。内容一律取自 `git archive <revision>`，所以打包的是被钉住的树，而不是工作区当前状态。
- 产物写入 `--output`（默认 `dist/`，已被 .gitignore 排除）：

| 产物 | 内容 |
|---|---|
| `agent-dev-template-<版本>.tar.gz` | 压缩包，单一顶层目录 `agent-dev-template-<版本>/`，解压无残留、无路径穿越 |
| `agent-dev-template-<版本>.manifest.txt` | `name/version/revision/format/files` 元数据 + 每个文件的 SHA-256 清单 |
| `agent-dev-template-<版本>.sha256` | tarball 的 SHA-256，格式兼容 `sha256sum -c` / `shasum -a 256 -c` |
| `agent-dev-template-<版本>.release-notes.md` | 发布说明**输入**（骨架含版本/revision/校验和/安装指引；`--notes` 用指定文件替换正文） |

`build-bundle.sh` 只构建、不发布：不调 `gh release`、不推送、不上传。发布属于后续独立流程——发布资产、检查单与（需明确授权的）发布指令见 [RELEASE.md](RELEASE.md)。

## 包里有什么（allowlist）

`scripts/bundle-allowlist.txt` 是显式白名单，一行一个路径（文件或目录，相对仓库根）。allowlist 列了但 revision 里不存在的路径会让构建**直接失败**——它是"消费者拿到什么"的契约，不是愿望清单。

| 类别 | 路径 |
|---|---|
| 运行时指令 | `AGENTS.md`、`CLAUDE.md` |
| 指南 | `README.md`、`INSTALL.md`、`CONTRIBUTING.md`、`docs` |
| 许可证 | `LICENSE` |
| 包元数据 | `package.json`（构建时盖版本号）、`package-lock.json`（`.agent/project.json` 声明的锁文件，让干净安装出的默认配置通过 `agent-preflight verify-project` 门） |
| Agent 角色配置 | `.agent` |
| 技能与本地命令 | `.claude/commands`、`.claude/skills`、`.codex/skills` |
| 安装/运行脚本 | `setup.sh`、`deploy.sh`、`scripts` |
| GitHub 自动化 | `.github/ISSUE_TEMPLATE`、`.github/PULL_REQUEST_TEMPLATE.md`、`.github/workflows` |
| Spec Kit 配置与模板 | `.specify` |
| 仓库卫生配置 | `.gitattributes`、`.gitignore` |

## 为什么有些东西永远不进包

两层防线：**白名单**决定进包内容；`build-bundle.sh` 里的 **deny list** 再扫一遍已暂存树，即使文件被误提交也会被剔除。分类理由：

| 排除项 | 理由 |
|---|---|
| `tests/` | 本仓库自身的验收测试，属于模板开发，不属于消费者运行时 |
| `scripts/build-bundle.sh`、`scripts/bundle-allowlist.txt` | 打包工具链本身，是本仓库的发布流程资产，不是分发内容 |
| `.specify/specs/` | 本仓库的 feature 规格（开发产物）；消费者用 Spec Kit 生成自己的 |
| `.git`、`.claude/worktrees/` | git 内部与本地 agent 工作区 |
| `.claude/settings.local.json`、`.claude/scheduled_tasks.lock` | 单机本地状态（个人设置、运行锁） |
| `.env`、`.env.*`、`*.env`、`*.pem`、`*.key`、`*.p12`、`secrets`/`secrets.*` | 凭证与环境文件——**绝不进包**，无论是否被误提交 |
| `*.log` | 运行日志 |
| `dist/`、`build/`、`coverage/`、`node_modules/`、`__pycache__/`、`.DS_Store` | 生成物、构建输出与本地缓存 |

此外，内容来自 `git archive`，工作区里未跟踪的脏东西（临时 env、日志、stale 产物）从一开始就进不了暂存树——deny list 是对"被误提交"情形的兜底。对应测试见 `tests/test-bundle.sh`（含 tracked/untracked 双向 sentinel）。

## 安装预览与已有定制的保护

分发包解压后即是完整模板，安装走既有部署路径 `deploy.sh`，并支持预览：

```bash
tar -xzf agent-dev-template-<版本>.tar.gz
cd agent-dev-template-<版本>
./deploy.sh --preview /path/to/your-repo   # 只看变更：+ 新增  = 一致  ! 冲突
./deploy.sh /path/to/your-repo             # 实际部署（已存在文件一律跳过，不覆盖）
```

- `+`：目标缺失，部署会新增；
- `=`：与模板完全一致；
- `!`：目标已存在且与模板不同（本地定制）——实际部署时**保留本地版本**，绝不覆盖；想吸收模板更新需手动 diff 合并。

预览模式不复制、不提交、不切分支、不推送，退出码 0。行为契约见 `tests/test-deploy-preview.sh`。

## 与 deploy 组件清单的关系

`deploy.sh` 的 `ITEMS` 是**安装**清单（往目标仓库放什么，刻意排除 README/LICENSE 等目标仓库自己的文件）；`bundle-allowlist.txt` 是**分发**清单（包里带什么，含指南与许可证，便于审计与模板化使用）。两份清单服务不同受众，有意不一致。
