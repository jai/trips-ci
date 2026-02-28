# AGENTS.md — Trips CI (`jai/trips-ci`)

## Repo Identity

- Shared GitHub Actions workflows for Trips repositories.
- Typical workflows include semantic PR checks, PR-issue linking, coverage, auto-merge, and code review orchestration.

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

## Structure

```
trips-ci/
├── .github/workflows/
├── docs/
└── scripts/
```

## Commands

- Validate workflow YAMLs (local checks as needed): `gh workflow list`
- Trigger/review runs via `gh run list`, `gh run view`, `gh run rerun`

## Owner

Jai Govindani (jai@govindani.com)
