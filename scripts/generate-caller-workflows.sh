#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/root/Developer/trips"
DEFAULT_REPOS=(trips api frontend worker infra fastlane)

if [[ "$#" -gt 0 ]]; then
  TARGETS=("$@")
else
  TARGETS=("${DEFAULT_REPOS[@]}")
fi

for target in "${TARGETS[@]}"; do
  if [[ "$target" = /* ]]; then
    repo_dir="$target"
  else
    repo_dir="$BASE_DIR/$target"
  fi

  workflow_path="$repo_dir/.github/workflows/code-review.yaml"
  mkdir -p "$(dirname "$workflow_path")"

  cat > "$workflow_path" <<'YAML'
name: Claude PR Assistant

on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  pull_request:
    types: [opened, reopened, ready_for_review, review_requested, synchronize]

permissions:
  contents: write
  issues: write
  pull-requests: write
  actions: read

concurrency:
  group: code-review-${{ github.repository }}-${{ github.event.pull_request.number || github.event.issue.number }}
  cancel-in-progress: false

jobs:
  welcome:
    name: Welcome comment
    if: >-
      github.event_name == 'pull_request' &&
      (github.event.action == 'opened' || github.event.action == 'reopened')
    uses: jai/trips-ci/.github/workflows/code-review-welcome.yaml@main
    secrets:
      GH_TOKEN: ${{ secrets.CLAUDE_REVIEW_GH_TOKEN }}

  full-review:
    name: Full code review
    if: >-
      (
        github.event_name == 'pull_request' &&
        (
          github.event.action == 'opened' ||
          github.event.action == 'reopened' ||
          github.event.action == 'ready_for_review' ||
          github.event.action == 'synchronize' ||
          github.event.action == 'review_requested'
        )
      ) ||
      (
        github.event_name == 'issue_comment' &&
        github.event.issue.pull_request &&
        startsWith(github.event.comment.body, '/review')
      )
    uses: jai/trips-ci/.github/workflows/code-review-full.yaml@main
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      CLAUDE_REVIEW_GH_TOKEN: ${{ secrets.CLAUDE_REVIEW_GH_TOKEN }}

  respond:
    name: Conversational @claude response
    if: >-
      (
        github.event_name == 'issue_comment' &&
        github.event.issue.pull_request &&
        contains(github.event.comment.body, '@claude') &&
        !startsWith(github.event.comment.body, '/')
      ) ||
      (
        github.event_name == 'pull_request_review_comment' &&
        contains(github.event.comment.body, '@claude')
      )
    uses: jai/trips-ci/.github/workflows/code-review-respond.yaml@main
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      CLAUDE_REVIEW_GH_TOKEN: ${{ secrets.CLAUDE_REVIEW_GH_TOKEN }}
YAML

  echo "Wrote: $workflow_path"
  cat "$workflow_path"
  echo
  echo "---"
  echo

done
