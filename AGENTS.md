> [!IMPORTANT]
> **Platform operational source of truth:** the central `jai/trips` repo owns current platform status and the operator manual. Read its `AGENTS.md` and `OPERATOR_MANUAL.md` before deploy or incident work; do not duplicate platform status here.

# AGENTS.md — Trips CI (`jai/trips-ci`)

## Repo Identity

- Shared GitHub Actions workflows for Trips repositories.
- Typical workflows include `pull-request-validation.yaml` (the canonical PR check covering semantic title, PR-issue linking, and required checks), `code-review*.yaml` (Codex review orchestration), `auto-merge.yaml`, `coverage-octocov.yml`, `issue-flow-gate.yaml`, `pr-image-check.yaml`, and `validate-workflows.yaml`.

## Project Mode (Solo MVP)

- One-person side project.
- Single operator and single user: Jai.
- Optimize CI changes for speed and reliability.
- Breaking workflow/interface changes are acceptable when they unblock delivery.
- Backward compatibility is not required during MVP.

## Non-Negotiable Guardrails

- Keep security boundaries around tokens, permissions, and comment/review automation.
- Prefer least-privilege GitHub Actions permissions.
- Use GitHub Issues/PRs only (no Linear).

## Workflow Defaults

- Prefer small workflow changes with clear validation.
- Avoid compatibility indirection unless explicitly requested.
- Ship quickly, but keep critical gating checks reliable.

## End-to-End Evidence Standard

- Follow the central `jai/trips` `AGENTS.md` end-to-end evidence standard.
- Workflow changes must preserve fail-fast CI behavior for production-like E2E checks and must not turn cross-repo feature evidence into sliced-only coverage.
- For email attachments, the expected CI evidence is a raw RFC822 email with an actual retained attachment flowing through worker ingest, API persistence/download endpoints, frontend UI visibility, and a successful attachment download.

## Structure

```
trips-ci/
├── .github/workflows/
├── docs/
├── scripts/
└── templates/
```

- `templates/` holds caller-workflow templates copied or rendered into each downstream repo's `.github/workflows/`. Today `scripts/generate-caller-workflows.sh` only renders `templates/code-review-caller.yaml` -> `code-review.yaml`; other templates here (e.g. `issue-flow-gate-caller.yaml`) are propagated manually or via other automation.

## Commands

- `scripts/generate-caller-workflows.sh [--check|--stdout] [target-dir...]` regenerates caller workflows in downstream repos. With no arguments it uses the hardcoded `DEFAULT_TARGETS` (umbrella subrepo paths under `/Users/jai/Developer/trips/`).
- `scripts/validate-workflows.sh` validates the rendered output.

## Owner

Jai Govindani (jai@govindani.com)
