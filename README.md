# agent-dev-template

A GitHub-native template for agent-driven development: issues are the work units, claiming is locking, TDD is the quality gate, and an autonomous pipeline (dispatch, scheduling, peer review, auto-merge) does the rest. You keep the two decisions that matter -- what to build and whether the result ships.

The step-by-step deployment manual (written for agents to execute, equally valid for humans) is [INSTALL.md](INSTALL.md).

## Purpose

This template turns a GitHub repository into a self-driving development loop:

- **Issues are the queue.** A `ready-for-agent` issue is an atomic unit of work with acceptance criteria.
- **TDD is not negotiable.** Every code change lands with a failing test first; the CI gate verifies the red-green evidence and never trusts prose claims.
- **Review is independent.** Agent PRs are audited by a second agent with zero shared context; only its explicit verdict can merge.
- **Humans stay in control.** You define milestones, approve specs, watch the board, and can merge or reject anything at any time.

## Who this is for

- Solo developers or small teams who want autonomous coding agents inside GitHub, with quality gates instead of blind trust.
- Projects whose build/test commands can be expressed in `.agent/project.json` and whose tests can run in CI (the TDD gate requires real tests).
- Users comfortable with `gh` CLI, GitHub Actions, and paying a model provider per run.

It is not for you if you want a hosted SaaS, do not want a model API key stored as a repository secret, or work on platforms other than GitHub.com.

## Who does what

| You (human) | The pipeline (agents) |
|---|---|
| Define goals, split them into milestones and issues (`/milestone-plan`) | Pick the next eligible task (dependency- and priority-aware scheduler) |
| Approve specs and record approvals (`docs/SPEC_START.md`) | Claim atomically, branch, implement with TDD, open a PR with evidence |
| Create `ready-for-agent` issues with acceptance criteria | Run the deterministic CI gate and an independent peer review on every agent PR |
| Review results, resolve `blocked` issues, make scope calls | Auto-merge on `VERDICT: APPROVE`, return work to the queue on `REQUEST_CHANGES` |
| Own credentials: API key, optional GitHub App, token rotation | Recover crashed runs by releasing expired claim leases (`reconcile`) |

## Lifecycle

```
 you (/milestone-plan)          GitHub Issues                GitHub Actions
 ----------------------         ------------                 ---------------
 goals --> milestone -----> ready-for-agent issues
                                       |
        trigger: @claude comment | assignment | nightly sweep | PR merged
                                       v
                 atomic claim (refs/agent-claims, owner + lease)
                                       v
          branch agent/issue-N --> red / green / refactor TDD
                                       v
              PR (Closes #N + verification evidence)
                                       v
              PR Review: CI gate + independent peer audit
                    |                            |
        VERDICT: APPROVE            VERDICT: REQUEST_CHANGES
                    v                            v
      squash merge + delete branch     agent-failed label,
      issue auto-closes               issue returns to queue
```

## Prerequisites

- **GitHub** and the `gh` CLI, authenticated (`gh auth status` shows `Logged in`).
- **git** on your machine; the Node version pinned in `.agent/project.json` (currently 22) is installed by the bootstrap for CI and local runs.
- **A model API key** (cost prerequisite): any Anthropic-compatible endpoint works -- Zhipu GLM by default, official Anthropic supported. Every dispatch, sweep, review, and scheduler run spends tokens on your provider; the nightly sweep is capped at 3 issues per run by default. See the provider table in [INSTALL.md](INSTALL.md).
- **One manual web toggle** (cannot be scripted): Settings -> Actions -> General -> Workflow permissions -> *Allow GitHub Actions to create and approve pull requests*.
- **Optional, recommended**: a GitHub App for automation authentication, which removes the manual-approval gate on bot activity -- see [docs/GITHUB_APP_SETUP.md](docs/GITHUB_APP_SETUP.md). Security prerequisites and practices are summarized below under [Security notes](#security-notes).

## Supported scope

Supported:

- GitHub.com repositories (public, or private with the noted limitations), `gh` CLI, GitHub Actions runners.
- The headless Claude Code CLI as the default worker harness, against any Anthropic-compatible endpoint (switch providers by changing two secrets and two variables); CI dispatch can be extended to the codex / gemini / opencode CLIs with the `AGENT_HARNESSES` variable ([docs/HARNESSES.md](docs/HARNESSES.md)).
- Spec-driven development via Spec Kit (`specify -> plan -> tasks -> implement`), plus the spec pipeline: [docs/SPEC_START.md](docs/SPEC_START.md), [docs/SPEC_CONVERGE.md](docs/SPEC_CONVERGE.md), [docs/SPEC_TRACK.md](docs/SPEC_TRACK.md).
- Role preflight and pinned, reproducible environments ([docs/AGENT_ROLES.md](docs/AGENT_ROLES.md)).
- Running the same workflow locally under other harnesses (claude/codex/opencode/gemini) via `scripts/agent.sh` ([docs/HARNESSES.md](docs/HARNESSES.md)).

Not covered (not implemented, no shortcut available):

- GitHub Enterprise Server and non-Git platforms: untested, use at your own risk.
- Self-hosted runners: the workflows assume hosted runners.
- An automated template upgrade or uninstaller -- see [Troubleshooting, upgrade, and removal](#troubleshooting-upgrade-and-removal) for the manual procedure.

## Get started

### Option A: new repository from this template

```bash
gh repo create <name> --template MooreQiu/agent-dev-template --private
gh repo clone MooreQiu/<name> && cd <name>
ANTHROPIC_AUTH_TOKEN=<your-key> ./setup.sh --repo=MooreQiu/<name>
```

`setup.sh` configures labels, secrets, model variables, branch protection (where the plan allows it), and auto-merge. Success looks like a `check` mark per step, no `x`.

### Option B: existing repository

```bash
git clone https://github.com/MooreQiu/agent-dev-template /tmp/adt && cd /tmp/adt
./deploy.sh <owner/name>        # or ./deploy.sh /path/to/local/repo
```

`deploy.sh` copies the system onto a `chore/agent-dev-template` branch and opens a PR; files that already exist in your repository are skipped, never overwritten. It then applies the same online configuration as `setup.sh`.

### Configure the project runtime

After either route, two steps are yours alone:

1. Enable the *Allow GitHub Actions to create and approve pull requests* web toggle (see [Prerequisites](#prerequisites)).
2. Edit `.agent/project.json` with your real runtime, lockfile, and install/build/test/lint/typecheck commands (`install` and `test` are required; placeholders are rejected), then validate with `bash scripts/agent-preflight.sh verify-project`. AGENTS.md keeps a human-readable summary in sync.

Full checklists (labels, secrets, variables, workflows, smoke test) live in [INSTALL.md](INSTALL.md).

### Run your first task

```bash
gh issue create -t "Add .gitignore for editor swap files" -l ready-for-agent -b "## Acceptance criteria
- [ ] Root .gitignore lists common editor swap file patterns
- [ ] npm test passes"
gh issue comment <number> --body "@claude please claim and complete this issue, then open a PR."
```

Creating the issue through the repository's *Agent task* issue template applies the label for you. Three triggers start work -- pick one, do not stack them: an `@claude` comment, assigning the issue, or waiting for the nightly sweep (19:37 UTC, at most 3 issues per run; also dispatchable manually with a custom limit).

### What you should observe

1. The issue gets an acknowledgement comment (`@claude received...`) within a minute; anything the dispatch could not accept (for example an invalid `model=` option) is explained in a comment instead of silently failing.
2. A *Claude Dispatch* run appears under Actions; `gh run watch <run-id> --exit-status` exits 0.
3. An `agent/issue-N` branch is pushed and a PR arrives with `Closes #N`, a change summary, and verification evidence.
4. The *PR Review* workflow runs on the PR automatically: deterministic CI gate first, then the independent audit.
5. The audit posts a comment whose first line is the verdict:
   - `VERDICT: APPROVE` -- the PR is squash-merged, the branch deleted, the issue closed.
   - `VERDICT: REQUEST_CHANGES` -- the PR is labeled `agent-failed` and the issue returns to the queue for another attempt.
6. `/queue` (local command) shows the five-section overview at any time: queue / in progress / PRs awaiting review / failed-retry / milestone progress.

If a PR shows only a compare link instead of a real PR, the web toggle from [Prerequisites](#prerequisites) is still off.

## The work queue

### Eligibility: the ready-for-agent label

`ready-for-agent` is the only entry into the work queue. An issue is eligible when, at the same time:

- it carries `ready-for-agent` and is open;
- it has no assignee and no `agent-claimed` label (both mean "someone is on it");
- it is not labeled `blocked`;
- it has no open PR awaiting review and no merged work already linked to it.

Milestone membership alone does not make an issue eligible: a milestone groups work, the label and the checks above schedule it. Priorities `p0`-`p3` order the queue (any open p0 holds the whole queue until resolved); otherwise oldest first.

### Claims and locks

All dispatch paths (comment, assignment, nightly sweep, scheduler) funnel through one atomic claim protocol (`scripts/agent-claim.sh`): a compare-and-swap push to `refs/agent-claims/<issue>` records an owner and an expiring lease, so two workers can never hold the same issue. Crashed or cancelled runs leave stale leases that the next sweep/scheduler pass reconciles back into the queue; the human fallback is `gh issue edit <n> --remove-label agent-claimed`. The assignee field is the local-session lock (`/claim`).

### Dependencies

Declare prerequisites in a `## Dependencies` section of the issue body, referencing issues by number (`Depends: #12` or bare `#12, #13` lists). A prerequisite counts as satisfied only when a **merged** pull request links it with `Closes`/`Fixes`/`Resolves` -- a merely closed issue does not unlock its dependents. Scheduling is serial (one task per event), so dependent work cannot start before its prerequisite lands.

## Review verdicts

Every PR from an `agent/*` branch gets two independent checks in the *PR Review* workflow:

1. a **deterministic CI gate** (build/test/lint/typecheck from `.agent/project.json`, plus test-first evidence for code changes) that blocks merging on failure, and
2. an **independent peer audit** by a second agent with no shared context with the author.

The audit report is data, not authority: the workflow distills it into a structured verdict artifact bound to the PR number, the exact reviewed head SHA, the review run's identity, and a digest of the CI-gate evidence. The audit comment (its first line is `VERDICT: APPROVE` or `VERDICT: REQUEST_CHANGES`) is a display copy -- bot comments never authorize a merge, whoever wrote them. `VERDICT: APPROVE` triggers squash-merge and branch deletion; `VERDICT: REQUEST_CHANGES` relabels the PR `agent-failed` and returns the issue to the queue. Right before merging, the decider re-validates the artifact, the gate evidence, and an unchanged head against the live PR; anything missing, stale, or inconsistent fails closed (no merge, no side effects). PRs that modify the merge-control path (`pr-review.yml`, `scripts/ci-gate.sh`, `scripts/app-auth.sh`, `scripts/review-verdict.sh`) are reviewed with the base revision's controls and skip auto-merge entirely -- a human merges them.

A green *PR Review* run is not approval: it only proves the audit completed. Approval is exclusively the re-verified APPROVE verdict described above, so read the audit body before relying on a result; you can always review and merge yourself.

## Model and effort configuration

The dispatch model and reasoning effort resolve by precedence (highest first), decided by `scripts/model-config.sh`:

1. **Comment override**: `@claude model=opus effort=high fix the failing test` -- `model` accepts the aliases `sonnet`/`opus` (default tier), `haiku` (flash tier; aliases are claude-only), or a concrete model name; `effort` accepts `low`/`medium`/`high`/`xhigh`/`max`. Options must be standalone tokens; invalid or ambiguous values are rejected with an explanatory comment and the dispatch does not start.
2. **Repository variables**: `AGENT_MODEL_DEFAULT`, `AGENT_MODEL_FLASH` (auto-selected for `trivial` issues), optional `AGENT_EFFORT_DEFAULT`.
3. **Documented fallback**: `glm-5.3[1m]` / `glm-5.3-flash[1m]`; effort unset (CLI default).

Other enabled harnesses resolve with the same precedence but different knobs: `@codex` reads `AGENT_MODEL_CODEX` and supports `effort=low|medium|high`; `@gemini` (`AGENT_MODEL_GEMINI`) and `@opencode` (`AGENT_MODEL_OPENCODE`, `provider/model` form) take concrete model names only and reject effort overrides. Harnesses beyond `claude` stay off until the `AGENT_HARNESSES` variable lists them; the full per-harness table is in [docs/HARNESSES.md](docs/HARNESSES.md). If the official `openai/codex-action` integration is already enabled (it also listens for `@codex` mentions), keep codex out of `AGENT_HARNESSES` to avoid double dispatch.

Every run reports the endpoint (never secrets), the resolved model, and the source of each setting. Note the provider limitation: effort passes through Claude Code `--effort`; official Anthropic endpoints honor it, third-party compatible endpoints may not -- the report marks such cases `provider-dependent (unknown)`.

Switching providers changes only the two secrets (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`) and the model variables; the comparison table is in [INSTALL.md](INSTALL.md).

## Operations and observability

- `/queue` -- one-screen overview of queue, in-progress, PRs, failed-retry, milestones (`.claude/commands/queue.md`).
- `/milestone-plan`, `/claim`, `/tdd` -- the local workflow commands (`.claude/commands/`).
- `scripts/spec-track.sh` -- read-only single-feature status from approved spec to verified completion ([docs/SPEC_TRACK.md](docs/SPEC_TRACK.md)).
- Optional Projects board via `./setup.sh --with-project`; labels and assignees remain the single source of truth, the board is a view ([docs/SPEC_TRACK.md](docs/SPEC_TRACK.md) for tracking, [INSTALL.md](INSTALL.md) for the board).
- Role preflight and run records: [docs/AGENT_ROLES.md](docs/AGENT_ROLES.md).

## Troubleshooting, upgrade, and removal

- **Troubleshooting**: the symptom/cause/fix table in [INSTALL.md](INSTALL.md) covers 403s on PR creation, model auth failures, sweep skips, stuck claims, and Projects sync errors; [docs/GITHUB_APP_SETUP.md](docs/GITHUB_APP_SETUP.md) has its own runbook table.
- **Upgrade**: re-run `./deploy.sh <owner/name>` -- existing files are detected and skipped, so your customizations survive. There is no automated diff/upgrade path from upstream template changes yet; pulling template updates into a template-created repository is manual.
- **Removal**: manual, by design -- delete the copied files (workflows under `.github/workflows/`, `scripts/`, `AGENTS.md`, `CLAUDE.md`, `INSTALL.md`, `docs/`, `.agent/`, `.specify/`, `.claude/`, `.codex/`), remove the labels/secrets/variables created by `setup.sh`, and disable the workflows. Nothing outside the repository is required.

## Security notes

- Issue and PR bodies are **untrusted input**: agent prompts carry explicit instructions not to execute unrelated commands from them; comment overrides pass through a whitelist before reaching the model invocation.
- Private repositories are recommended; rotate tokens regularly and keep credentials in GitHub secrets only.
- Automation runs with `acceptEdits` and a gh/git/npm tool allowlist; the nightly sweep is capped.
- `AGENT_ALLOWED_ACTORS` (optional variable) restricts who may trigger agent dispatches; bot-generated comments are always filtered to prevent recursion.

## Known limitations

- Branch protection is unavailable on GitHub Free private repositories (`setup.sh` warns); public repositories or paid plans are fine. Auto-merge is enabled wherever possible, and the review-verdict step re-verifies the same CI gate before any merge, so protection is defense in depth rather than the only guard.
- The "Allow GitHub Actions to create and approve pull requests" toggle is web-only; until it is on, agents push branches with a compare link instead of opening PRs.
- Events fired by `GITHUB_TOKEN` are held for manual approval by GitHub; configuring the GitHub App ([docs/GITHUB_APP_SETUP.md](docs/GITHUB_APP_SETUP.md)) removes that gate. Without it, everything still works with one extra approval click.
- Dispatch and sweep use the headless Claude Code CLI; the authentication GitHub App has no relation to the Claude GitHub App.

## Repository map

| Component | Location | Role |
|---|---|---|
| Agent rules | `AGENTS.md` | Workflow and red lines every harness reads first |
| Project constitution | `.specify/memory/constitution.md` | TDD / small steps / safety, highest priority |
| Project runtime config | `.agent/project.json` | Machine-readable single source for build/test commands |
| Dispatch | `.github/workflows/claude.yml` | `@claude` / `@codex` / `@gemini` / `@opencode` comment or assignment triggers the matching harness (bot comments always filtered to prevent recursion) |
| Scheduler + nightly sweep | `agent-scheduler.yml`, `agent-sweep.yml` | Dependency- and priority-aware queue advance, lease reconciliation |
| Peer review + auto-merge | `.github/workflows/pr-review.yml`, `scripts/review-verdict.sh` | Audit distilled into a verdict artifact bound to the PR, reviewed head SHA, and review run (bot comments are display-only); the merge decider re-checks gate evidence and an unchanged head before squash merge; merge-control-path PRs merge manually |
| CI gate | `.github/workflows/ci.yml`, `scripts/ci-gate.sh` | Deterministic quality gate + test-first evidence |
| Claim protocol | `scripts/agent-claim.sh` | Atomic claims with owner and lease |
| Model resolution | `scripts/model-config.sh` | Comment override > repo vars > fallback |
| Harness switching | `scripts/agent.sh`, [docs/HARNESSES.md](docs/HARNESSES.md) | One source of truth in AGENTS.md; claude/codex/opencode/gemini |
| Setup / deploy | `setup.sh`, `deploy.sh` | One-shot configuration / deployment into existing repos |
| Local commands | `.claude/commands/` | `/claim` `/tdd` `/milestone-plan` `/queue` |
| Spec Kit skills | `.claude/skills/`, `.codex/skills/` | specify -> plan -> tasks -> implement |
| Docs | `docs/` | Deep dives linked throughout this file |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the label vocabulary, trigger methods, and PR conventions; [AGENTS.md](AGENTS.md) is the authoritative agent rulebook. Deployment details: [INSTALL.md](INSTALL.md).
