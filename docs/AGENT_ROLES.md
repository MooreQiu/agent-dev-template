# Agent 角色手册（Bootstrap 与预检）

本仓库的 agent 工作按角色划分：**specify**（写规格）、**implement**（TDD 实现）、**review**（审计）。每个角色开工前必须通过预检，保证指令、规格产物、技能与工具齐备。角色定义的单一事实源是 `.agent/roles.json`。

## 快速使用

```bash
bash scripts/agent-preflight.sh verify-project                     # 校验项目运行时配置
bash scripts/agent-preflight.sh verify <specify|implement|review>   # 预检 + 写运行记录
bash scripts/agent-preflight.sh note-invocation <role> <skill>      # 记录一次显式技能调用
bash scripts/sync-skills.sh                                         # 同步技能到 Codex（--check 只校验）
```

预检必须在仓库根目录运行；任何一项缺失都会以可操作的错误信息退出（缺哪个文件/技能/工具、如何修复），退出码：0 通过、1 缺要件、2 用法错误。

## 角色定义（.agent/roles.json）

| 角色 | 阶段技能（必须显式调用） | 指令文件 | 规格产物 | 支持脚本 | 工具 |
|---|---|---|---|---|---|
| specify | `speckit-specify`、`speckit-clarify`、`speckit-plan`、`speckit-tasks` | AGENTS.md、constitution.md | spec/checklist/plan/tasks 模板 | check-prerequisites、common、resolve-template、create-new-feature、setup-plan、setup-tasks | git、gh |
| implement | `speckit-implement`、`speckit-converge` | AGENTS.md、constitution.md | plan/tasks 模板 | check-prerequisites、common、setup-plan、setup-tasks | git、gh、node、npm |
| review | `speckit-analyze`、`speckit-checklist` | AGENTS.md、constitution.md | plan/tasks/checklist 模板 | common | git、gh、node、npm |

调用语法（`invocation_syntax`）：Claude Code 用 `/speckit-*`，Codex 用 `$speckit-*`。**不要依赖自动发现**——按角色映射显式调用对应技能，调用后用 `note-invocation` 留痕。

## 双 harness 技能发现（单一事实源 + 同步机制）

- 单一维护源：`.claude/skills/`（Spec Kit 安装、Claude Code 自动发现）。
- Codex 侧副本：`.codex/skills/`，由 `scripts/sync-skills.sh` 从源镜像生成，并刷新 `.specify/integrations/codex.manifest.json` 的 sha256 清单。
- `.specify/integration.json` 声明 claude 与 codex 双集成（codex 调用分隔符为 `$`）。
- CI/Actions runner 上没有个人机器技能，仓库技能是唯一来源；改动技能后必须重跑 `sync-skills.sh`（预检和 `--check` 都会拦漂移）。

### 如何加入项目专属技能

1. 新建 `.claude/skills/<name>/SKILL.md`，frontmatter 必须含 `name:` 与 `description:`；
2. 运行 `bash scripts/sync-skills.sh`（生成 `.codex/skills/<name>/` 并更新清单）；
3. 若某角色必须用到它，把 `<name>` 加进 `.agent/roles.json` 对应角色的 `skills` 数组；
4. 提交源、副本与清单——三者由 `tests/test_agent_bootstrap.sh` 校验一致。

## 运行记录与证据（不泄露 secrets）

`verify` 通过后写 `.agent/runs/preflight-<role>-<时间戳>.json`（目录已 gitignore），内容包括：

- `role`：本次选择的角色；
- `model`：取 `AGENT_MODEL` → `ANTHROPIC_DEFAULT_SONNET_MODEL` → `unset`（只读模型名，绝不读取 token/key 类环境变量，也不要往 `AGENT_MODEL` 里放凭证）；
- `instruction_revision`：当前 commit 及 AGENTS.md / constitution.md 的内容哈希（git blob id）；
- `evidence.discovered`：发现的技能及内容哈希与来源目录；
- `evidence.invoked`：初始为空。

**发现 ≠ 调用**：实际显式调用某技能后，运行 `note-invocation <role> <skill>`，证据追加到 `.agent/runs/invocations.jsonl`（带 run 文件名、角色、技能、时间）。审计时以 jsonl 为调用证据、以 record 的 `discovered` 为发现证据。

## 项目运行时与环境引导（.agent/project.json）

AGENTS.md「项目信息」的机器可读单一事实源是 `.agent/project.json`，实现与审计（review）环境共用同一套引导：

| 字段 | 含义 |
|---|---|
| `runtime.name` / `runtime.version` | 项目运行时；node 必须钉住版本，`bootstrap-env.sh` 会校验本机 node 主版本一致，非 node 运行时走配置的 `commands.install` |
| `runtime.lockfile` | 锁文件；留空则自动探测 `package-lock.json` / `yarn.lock` / `pnpm-lock.yaml`，命中即用冻结安装（`npm ci` / `--frozen-lockfile`） |
| `commands.install/build/test/lint/typecheck` | 安装/构建/相关测试/lint/类型检查命令；`install` 与 `test` 必填，其余可留空但不得留占位符（`待填`/`TODO`/`TBD` 会被拒绝） |
| `agent_tooling.claude_code` | 钉住的 Claude Code CLI 版本（必须是精确版本号，`latest` 被拒绝） |
| `integrations` | 需要的 agent 集成（当前支持 `claude`），引导后逐一验证在 PATH |
| `model_auth.any_of_env` | 模型认证环境变量（任一非空即通过；只检查存在性，值绝不打印） |

```bash
bash scripts/bootstrap-env.sh            # 校验配置 → 认证/非交互校验 → lockfile 安装 → 装钉住的 CLI → 验证集成
bash scripts/bootstrap-env.sh --check    # 只校验配置与前提，不安装
```

引导全程 fail-fast：配置缺命令/占位符、node 版本不一致、模型认证缺失、gh 未认证、依赖或工具安装失败、集成缺失——一律立即报错退出，绝不挂起等交互输入（`GIT_TERMINAL_PROMPT=0`、`GH_PROMPT_DISABLED=1`，CI 中写入 `GITHUB_ENV`）。五个工作流（claude / agent-sweep / pr-review / spec-start / spec-converge）统一通过 `scripts/bootstrap-env.sh` 引导，不再手写未钉住的安装命令；spec 类工作流在引导后仍保留各自的角色预检（spec-start 预检 specify、spec-converge 预检 implement）。

**接入具体项目的设置路径**：1) 编辑 `.agent/project.json` 填真实命令与锁文件；2) `verify-project` 校验（角色 `verify` 也会自动校验并拒绝无效配置）；3) 工作流保持 `scripts/bootstrap-env.sh` 引导步骤即可复现环境。

## 测试

验收测试在 `tests/test_agent_bootstrap.sh` 与 `tests/test-project-runtime.sh`（`npm test` 会一并运行），前者覆盖：角色选择、缺文件/缺技能/坏元数据/脚本不可执行、错误工作目录、缺工具启动失败、记录与秘密不泄露、双 harness 同步与漂移、项目专属技能接入；后者覆盖：项目配置校验（缺命令/占位符/未钉版本/未知集成/坏锁文件）、角色预检联动、可复现引导（lockfile 语义、钉住 CLI、认证与非交互 fail-fast）、非 Node 项目、安装与命令执行失败、五个工作流（含 spec-start / spec-converge）统一走共享引导且无未钉安装；spec 工作流侧的接线（共享引导先于角色预检、失败不遮蔽、保留 setup-node）另由 `tests/test-spec-start.sh` / `tests/test-spec-converge.sh` 校验。
