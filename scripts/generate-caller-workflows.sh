#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/code-review-caller.yaml"

DEFAULT_TARGETS=(
  "/Users/jai/Developer/trips"
  "/Users/jai/Developer/trips/api"
  "/Users/jai/Developer/trips/frontend"
  "/Users/jai/Developer/trips/worker"
  "/Users/jai/Developer/trips/infra"
  "/Users/jai/Developer/trips-fastlane"
)

mode="write"
if [[ "${1:-}" == "--check" ]]; then
  mode="check"
  shift
fi

if [[ "$#" -gt 0 ]]; then
  TARGETS=("$@")
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

for target in "${TARGETS[@]}"; do
  repo_dir="$target"
  workflow_path="$repo_dir/.github/workflows/code-review.yaml"

  if [[ "$mode" == "check" ]]; then
    if ! cmp -s "$TEMPLATE" "$workflow_path"; then
      echo "Out of date: $workflow_path" >&2
      diff -u "$TEMPLATE" "$workflow_path" || true
      exit 1
    fi
    echo "Current: $workflow_path"
  else
    mkdir -p "$(dirname "$workflow_path")"
    cp "$TEMPLATE" "$workflow_path"
    echo "Wrote: $workflow_path"
  fi

done
