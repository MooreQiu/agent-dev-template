# agent-dev-template 0.1.0 (trial release)

The first packaged release of the agent-driven development template: a GitHub-native loop where issues are the work units, claiming is locking, TDD is the quality gate, and an autonomous pipeline (dispatch, scheduling, independent peer review, auto-merge) runs the rest.

This is a **trial release**: reviewable and auditable, but not a long-term-support line. "Trial expectations" at the end of this document defines exactly what that means.

## Tested capabilities

Every capability below is covered by the acceptance suites shipped in the repository (`npm test` runs them all). The autonomous lifecycle is additionally validated end to end by `tests/test-e2e-lifecycle.sh`, which wires the real orchestration chain inside a disposable fixture repository and is exercised as a scheduled Actions smoke workflow.

- **Work queue and scheduling.** `ready-for-agent` eligibility with no assignee, no claim, and no open work; atomic claims through a compare-and-swap ref carrying an owner and an expiring lease, with crash recovery by lease reconciliation; dependency- and priority-aware serial scheduling; nightly sweep capped at 3 issues per run.
- **TDD enforcement.** A deterministic CI gate runs the install/build/test/lint/typecheck commands configured in `.agent/project.json` and verifies test-first (red then green) evidence over the reviewed commit range; an implementation without a failing test first is rejected. Durable run budgets (retry, repair, convergence, duration, steps) fail closed when exhausted.
- **Independent review and auto-merge.** Every agent PR is audited by a second agent with zero shared context; the audit is distilled into a verdict artifact bound to the PR number, the exact reviewed head SHA, the review run identity, and a digest of the CI-gate evidence. `VERDICT: APPROVE` squash-merges only after the decider re-verifies the artifact, the evidence, and an unchanged head against the live PR (fail closed on anything missing or stale). `VERDICT: REQUEST_CHANGES` relabels the PR and returns the issue to the queue, where an automatic repair loop picks it up. A watchdog detects silent review failures; verdicts are surfaced as native PR review status; a posted verdict is honored even when the reviewer process exits non-zero. PRs touching the merge-control path always merge manually.
- **Spec-driven development.** Spec Kit integration: planning starts from an approved spec and generates deduplicated issues; convergence is gated on an explicit precheck; a read-only tracker reports per-feature status; approved features advance between stages automatically; planning and convergence artifacts are versioned; completion requires requirement-level verifiable evidence.
- **Multi-harness dispatch.** `@claude` (headless Claude Code CLI) is the default worker harness; `@codex`, `@gemini`, and `@opencode` are opt-in through the `AGENT_HARNESSES` repository variable. Model and effort resolve by documented precedence (comment override, then repository variables, then the documented fallback); invalid or ambiguous options are rejected with an explanation before any dispatch starts.
- **Distribution and installation.** A versioned distribution bundle (tarball, per-file SHA-256 manifest, `sha256sum -c` compatible checksum file) is built from an immutable full-SHA revision through an explicit allowlist, with a deny list that keeps secrets, local state, logs, and generated artifacts out of the package even if committed by accident. Installation into clean and existing repositories is verified, with preview and never-overwrite conflict behavior; local customizations survive upgrades. A pinned, reproducible bootstrap (Node 22 plus pinned agent CLIs) is derived from `.agent/project.json` in every workflow.
- **Documentation.** README as the first-run front door, a step-by-step INSTALL manual written for agent execution, operations and run-control guides, an upgrade/conflict/rollback/removal guide, and a GitHub App setup runbook.

## Known limitations

- Branch protection is unavailable on GitHub Free **private** repositories (setup warns); public repositories and paid plans are fine. Where protection cannot be set, the merge decider re-runs the same CI gate before merging, so protection is defense in depth rather than the only guard.
- The "Allow GitHub Actions to create and approve pull requests" toggle is web-only and cannot be scripted; until it is enabled, agents push branches with compare links instead of opening pull requests.
- Events fired by `GITHUB_TOKEN` are held for manual approval by GitHub; configuring the optional GitHub App removes that gate. Without it, everything works with one extra approval click.
- There is no automated upgrade or uninstaller. Upgrading means re-running `deploy.sh` (existing files are skipped, never overwritten) and manually diff-merging customized files against the template.
- Reasoning `effort` is honored by official Anthropic endpoints; third-party compatible endpoints may ignore it. Runs report such cases as `provider-dependent (unknown)` instead of promising an effect.
- Scheduling is serial: one task per triggering event, and the nightly sweep processes at most 3 issues per run.

## Supported combinations

- **Platform**: GitHub.com repositories (public or private), an authenticated `gh` CLI, and GitHub Actions hosted runners. GitHub Enterprise Server, other git hosts, and self-hosted runners are not supported.
- **Worker harnesses**: the headless Claude Code CLI (version pinned in `.agent/project.json`, 2.1.295 at the time of this release) against any Anthropic-compatible endpoint - Zhipu GLM by default, official Anthropic supported. Opt-in harnesses: codex CLI (0.162.0), gemini CLI (0.63.0), opencode CLI (1.18.35), enabled via `AGENT_HARNESSES`. Harnesses or combinations not listed in the documentation are not supported in 0.1.0.
- **Local runtime**: Node 22 (the version pinned in `.agent/project.json`); local scripts run on macOS (BSD userland) and Linux (GNU userland), both guarded by the portability suite.

## Required accounts and permissions

- **GitHub account**: `gh` authenticated; the account running setup or deploy needs **admin** on the target repository (secrets, variables, branch protection, auto-merge). Daily use - commenting `@claude`, claiming issues - needs write access only.
- **Model provider account**: a Zhipu GLM API key (default) or an Anthropic API key, or any Anthropic-compatible endpoint, stored as the `ANTHROPIC_AUTH_TOKEN` secret. Every dispatch, sweep, review, and scheduler run spends tokens on this account; see the cost responsibilities in docs/RELEASE.md.
- **One manual web toggle**: Settings, then Actions, then General, then Workflow permissions, then *Allow GitHub Actions to create and approve pull requests*.
- **Optional**: a GitHub App for automation authentication, which removes the manual-approval gates; the setup runbook is docs/GITHUB_APP_SETUP.md.

## Installation and verification

- **New repository**: create it from the GitHub template, clone, run `ANTHROPIC_AUTH_TOKEN=<your-key> ./setup.sh --repo=<owner/name>`, then follow INSTALL.md for the mandatory manual steps and the smoke test.
- **Existing repository**: clone this template, run `./deploy.sh <owner/name>` (or a local repository path). Existing files are skipped, never overwritten.
- **Versioned bundle** (auditable / offline): download `agent-dev-template-0.1.0.tar.gz` and `agent-dev-template-0.1.0.sha256` from the release page, verify with `sha256sum -c agent-dev-template-0.1.0.sha256` (or `shasum -a 256 -c`), extract, then run `./deploy.sh --preview /path/to/your-repo` followed by `./deploy.sh /path/to/your-repo`. The per-file manifest (`agent-dev-template-0.1.0.manifest.txt`) lists the exact contents and hashes of the bundle; the source revision and tarball checksum are recorded on the release page.

## Feedback

- **Bugs**: open an issue with the bug report template (`.github/ISSUE_TEMPLATE/01-bug.yml`), including reproduction steps.
- **Feature requests**: the feature template (`.github/ISSUE_TEMPLATE/02-feature.yml`).
- **Security problems**: do not open a public issue. Use GitHub private vulnerability reporting (Security, then Report a vulnerability) when enabled; otherwise contact the maintainer (@MooreQiu) for a private channel without posting details publicly.
- **Agent-run failures**: dispatch, sweep, and review failures are reported as comments on the affected issue - start there before filing a new bug.

## Trial expectations

- The supported surface is exactly what README.md ("Supported scope") and docs/RELEASE.md describe. Routes the documentation marks as unsupported - experimental harnesses, GitHub Enterprise Server, self-hosted runners, automated upgrades - remain unsupported in this release even where a partial shortcut exists.
- Behavior may change between 0.x releases; there is no cross-minor-version compatibility guarantee yet. The versioning and upgrade policy is documented in docs/RELEASE.md and docs/UPGRADE.md.
