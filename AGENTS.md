> [!IMPORTANT]
> **Platform operational source of truth:** the central `jai/trips` repo owns current platform status and the operator manual. Read its `AGENTS.md` and `OPERATOR_MANUAL.md` before deploy or incident work; do not duplicate platform status here.

> [!TIP]
> **Start here for platform questions** (all owned by `jai/trips`): where CI runs (Jai's laptop `borg-cube-03`, ephemeral runners) → [`docs/ci-runners.md`](https://github.com/jai/trips/blob/main/docs/ci-runners.md); iOS build / TestFlight → [`docs/ios-release.md`](https://github.com/jai/trips/blob/main/docs/ios-release.md); feature backlog and what is in flight → [`docs/FEATURE_PIPELINE.md`](https://github.com/jai/trips/blob/main/docs/FEATURE_PIPELINE.md). If this file disagrees with those, the umbrella wins; fix this file.

# AGENTS.md — Trips CI (`jai/trips-ci`)

## Repo Identity

- Shared GitHub Actions workflows for Trips repositories.
- Workflows: `code-review*.yaml` (Codex PR review orchestration, called by non-Trips repos; Trips repos run `codex review` locally before each push), `auto-merge.yaml` (enables auto-merge on Dependabot and OpenAPI-sync PRs), `coverage-octocov.yml`, and `validate-workflows.yaml` (this repo's own CI).
- Runner controllers that execute all private Trips CI on Jai's laptop `borg-cube-03` and, for Linux, on `borg-cube-04`:
  - `scripts/trips-linux-lima-runner-controller.zsh` — ephemeral Lima Ubuntu ARM64 slots, labels `self-hosted, linux, arm64, jai-ci`.
    Both slots select native preparation, deployment, validation (`jai-ci-validation`; no Trips workflow requests it now), delivery CI, then general jobs; active jobs finish before the next selection. Deploy the controller before retriggering callers to use the updated reusable workflow.
    `borg-cube-03` runs slots `a` and `b` at the default budget. `borg-cube-04` runs `a` to `d` with its budget in `~/.config/trips-ci/host.env`.
  - `scripts/trips-tart-runner-controller.zsh` — one ephemeral macOS Tart slot for iOS build / TestFlight / Maestro, labels `self-hosted, macOS, ARM64, tart, ios`.
  - `scripts/trips-android-host-runner-controller.zsh` — ephemeral Android host runner, labels `self-hosted, macOS, ARM64, borg-cube-03, android`; shares the native lane lock with iOS.
  - `launchd/*.plist` keep the controllers running headlessly; `scripts/provision-*-runner-base.zsh` build the base images.
- This repo is public and its own CI runs on GitHub-hosted `ubuntu-latest`.

## Project Mode (Solo MVP)

- One-person side project.
- Single operator and single user: Jai.
- Features are built from Jai's specs: the linked `jai/trips` issue body is the spec. Build what it says and do not invent scope; ask on the issue when it is ambiguous.
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
- After pushing controller changes, redeploy the exact scripts/plists to `borg-cube-03` and `borg-cube-04` (wrappers in `~/.local/bin/`) and record the result in working memory.

## End-to-End Evidence Standard

- Follow the central `jai/trips` `AGENTS.md` end-to-end evidence standard.
- Workflow changes must preserve fail-fast CI behavior for production-like E2E checks and must not turn cross-repo feature evidence into sliced-only coverage.
- For email attachments, the expected CI evidence is a raw RFC822 email with an actual retained attachment flowing through worker ingest, API persistence/download endpoints, frontend UI visibility, and a successful attachment download.

## Structure

```
trips-ci/
├── .github/workflows/   # reusable workflows called by every Trips repo
├── docs/                # runner and workflow runbooks
├── launchd/             # com.jai.trips-*-runner*.plist controller agents
├── scripts/             # runner controllers, base-image provisioning, caller generation
├── templates/           # caller-workflow templates rendered into downstream repos
└── tests/               # controller and workflow tests
```

- `templates/code-review-caller.yaml` is the caller workflow for repos that use the shared Codex PR review; `scripts/generate-caller-workflows.sh` renders it into the target repos you name.

## Commands

- `scripts/generate-caller-workflows.sh [--check|--stdout] <target-dir>...` renders `code-review.yaml` into the named downstream repos. Trips repos do not call it.
- `scripts/validate-workflows.sh` validates the rendered output.
- Laptop health check: `launchctl list | grep com.jai.trips`, `tart list`, `limactl list`, and the controller logs under `~/Library/Logs/trips-*-runner/`.

## Owner

Jai Govindani (jai@govindani.com)
