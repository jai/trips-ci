> [!IMPORTANT]
> **Platform operational source of truth:** the central `jai/trips` repo owns current platform status and the operator manual. Read its `AGENTS.md` and `OPERATOR_MANUAL.md` before deploy or incident work; do not duplicate platform status here.

> [!TIP]
> **Start here for platform questions** (all owned by `jai/trips`): where CI runs (Jai's laptop `borg-cube-03`, ephemeral runners) → [`docs/ci-runners.md`](https://github.com/jai/trips/blob/main/docs/ci-runners.md); iOS build / TestFlight → [`docs/ios-release.md`](https://github.com/jai/trips/blob/main/docs/ios-release.md); feature backlog and what is in flight → [`docs/FEATURE_PIPELINE.md`](https://github.com/jai/trips/blob/main/docs/FEATURE_PIPELINE.md). If this file disagrees with those, the umbrella wins; fix this file.

# AGENTS.md — Trips CI (`jai/trips-ci`)

## Repo Identity

- Shared GitHub Actions workflows for Trips repositories.
- Typical workflows include `pull-request-validation.yaml` (the canonical PR check covering semantic title, PR-issue linking, and required checks), `code-review*.yaml` (Codex review orchestration), `auto-merge.yaml`, `coverage-octocov.yml`, `issue-flow-gate.yaml`, `pr-image-check.yaml`, and `validate-workflows.yaml`.
- Runner controllers that execute all private Trips CI on Jai's laptop `borg-cube-03`:
  - `scripts/trips-linux-lima-runner-controller.zsh` — two ephemeral Lima Ubuntu ARM64 slots (`a`, `b`), labels `self-hosted, linux, arm64, jai-ci`.
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
- Use GitHub Issues/PRs only (no Linear).

## Workflow Defaults

- Prefer small workflow changes with clear validation.
- Avoid compatibility indirection unless explicitly requested.
- Ship quickly, but keep critical gating checks reliable.
- After merging controller changes, redeploy the exact scripts/plists to `borg-cube-03` (wrappers in `~/.local/bin/`) and record the result in working memory.

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

- `templates/` holds caller-workflow templates copied or rendered into each downstream repo's `.github/workflows/`. Today `scripts/generate-caller-workflows.sh` only renders `templates/code-review-caller.yaml` -> `code-review.yaml`; other templates here (e.g. `issue-flow-gate-caller.yaml`) are propagated manually or via other automation.

## Commands

- `scripts/generate-caller-workflows.sh [--check|--stdout] [target-dir...]` regenerates caller workflows in downstream repos. With no arguments it uses the hardcoded `DEFAULT_TARGETS` (umbrella subrepo paths under `/Users/jai/Developer/trips/`).
- `scripts/validate-workflows.sh` validates the rendered output.
- Laptop health check: `launchctl list | grep com.jai.trips`, `tart list`, `limactl list`, and the controller logs under `~/Library/Logs/trips-*-runner/`.

## Owner

Jai Govindani (jai@govindani.com)
