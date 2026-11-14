> [!IMPORTANT]
> **Platform operational source of truth:** the central `viators-net/trips` repo owns current platform status and the operator manual. Read its `AGENTS.md` and `OPERATOR_MANUAL.md` before deploy or incident work; do not duplicate platform status here.

> [!TIP]
> **Start here for platform questions** (all owned by `viators-net/trips`): where CI runs (Jai's laptop `borg-cube-03`, ephemeral runners) → [`docs/ci-runners.md`](https://github.com/viators-net/trips/blob/main/docs/ci-runners.md); iOS build / TestFlight → [`docs/ios-release.md`](https://github.com/viators-net/trips/blob/main/docs/ios-release.md); feature backlog and what is in flight → [`docs/FEATURE_PIPELINE.md`](https://github.com/viators-net/trips/blob/main/docs/FEATURE_PIPELINE.md). If this file disagrees with those, the umbrella wins; fix this file.

# AGENTS.md — Trips CI (`viators-net/trips-ci`)

**CI rules:** before you add or change a workflow, or build, test, run a simulator or drive a desktop on one of
Jai's Macs, read [RULES.md in jai/ci](https://github.com/jai/ci/blob/main/RULES.md).

<!-- BEGIN jai/ci standard section -->
## Shipping (standard for all of Jai's projects)

- **Push to main.** Work on `main` in your own clone or worktree. No feature branches and
  no pull requests. The only pull requests are the ones bots open (Dependabot,
  release-please); they merge themselves once green.
- **Land a change:** commit small (Conventional Commits, signed), `git pull --rebase origin
  main`, run this repo's fast checks, push. A push rejected because main moved means
  someone landed first: rebase, run the checks again, push again. Never force-push.
- **Main stays green.** Watch the run for your commit (`gh run watch`). If your push turns
  main red, fixing it is your next task: fix forward, or `git revert` your commit, within
  the hour.
- **Releases are not yours to cut.** An hourly job tests main's newest commit and releases
  it if it passes. Do not tag or bump versions by hand.
- **Unfinished work** goes behind a feature flag, not on a branch.
- **Parallel agents:** one worktree each, small changes, rebase often.
- **Where CI runs and what you may run on Jai's Macs:**
  [RULES.md in jai/ci](https://github.com/jai/ci/blob/main/RULES.md).
<!-- END jai/ci standard section -->

## Repo Identity

- Shared GitHub Actions workflows for Trips repositories.
- Workflows: `code-review*.yaml` (Codex PR review orchestration, called by non-Trips repos; Trips repos run `codex review` locally before each push), `auto-merge.yaml` (enables auto-merge on Dependabot and OpenAPI-sync PRs), `coverage-octocov.yml`, and `validate-workflows.yaml` (this repo's own CI).
- `runscaler/` holds the Linux image and config (`Dockerfile`, `config.toml`) and the iOS config (`tart.toml`). `launchd/` starts them on `borg-cube-03`. `config-borg-cube-04.toml`, `tart-borg-cube-04.toml` and `config-mac-mini.toml` are the fallback hosts' configs (suffixed scale-set names, same labels). How to change and check them: `viators-net/trips` `docs/ci-runners.md`.
- This repo is public and its own CI runs on GitHub-hosted `ubuntu-latest`.

## Project Mode (Solo MVP)

- One-person side project.
- Single operator and single user: Jai.
- Features are built from Jai's specs: the linked `viators-net/trips` issue body is the spec. Build what it says and do not invent scope; ask on the issue when it is ambiguous.
- Optimize CI changes for speed and reliability.
- Breaking workflow/interface changes are acceptable when they unblock delivery.
- Backward compatibility is not required during MVP.

## Non-Negotiable Guardrails

- Keep security boundaries around tokens, permissions, and comment/review automation.
- Prefer least-privilege GitHub Actions permissions.
- Runners are always registered `--ephemeral` and destroyed after one job; do not introduce persistent runners, GitHub-hosted macOS, or host-name labels in downstream workflows.
- Track work in GitHub Issues (no Linear).

## Workflow Defaults

- Push to `main`; do not open pull requests. Factory stages are the exception: they follow their stage prompt, which opens and merges a PR. Before each push, run `codex review --base origin/main` and fix what it finds; `validate-workflows.yaml` runs on the push.
- Prefer small workflow changes with clear validation.
- Avoid compatibility indirection unless explicitly requested.
- Ship quickly, but keep critical gating checks reliable.

## End-to-End Evidence Standard

- Follow the central `viators-net/trips` `AGENTS.md` end-to-end evidence standard.
- Workflow changes must preserve fail-fast CI behavior for production-like E2E checks and must not turn cross-repo feature evidence into sliced-only coverage.
- For email attachments, the expected CI evidence is a raw RFC822 email with an actual retained attachment flowing through worker ingest, API persistence/download endpoints, frontend UI visibility, and a successful attachment download.

## Structure

```
trips-ci/
├── .github/workflows/   # reusable workflows called by every Trips repo
├── docs/                # runner and workflow runbooks
├── launchd/             # Colima boot job
├── runscaler/           # runner image and configs
├── scripts/             # base-image provisioning, caller generation
├── templates/           # caller-workflow templates rendered into downstream repos
└── tests/               # provisioning tests
```

- `templates/code-review-caller.yaml` is the caller workflow for repos that use the shared Codex PR review; `scripts/generate-caller-workflows.sh` renders it into the target repos you name.

## Commands

- `scripts/generate-caller-workflows.sh [--check|--stdout] <target-dir>...` renders `code-review.yaml` into the named downstream repos. Trips repos do not call it.
- `scripts/validate-workflows.sh` validates the rendered output.

## Owner

Jai Govindani (jai@govindani.com)
