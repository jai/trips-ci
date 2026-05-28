#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$repo_root/tmp/workflow-validation"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

rm -rf "$tmp_dir"
mkdir -p "$tmp_dir/.github/workflows"
"$repo_root/scripts/generate-caller-workflows.sh" --stdout \
  /Users/jai/Developer/trips \
  > "$tmp_dir/.github/workflows/code-review.yaml"
"$repo_root/scripts/generate-caller-workflows.sh" --stdout \
  /Users/jai/Developer/trips-fastlane \
  > "$tmp_dir/.github/workflows/code-review-fastlane.yaml"

actionlint_args=(
  -shellcheck=
  -ignore 'label "ubicloud-standard-2" is unknown'
)

actionlint "${actionlint_args[@]}" "$repo_root"/.github/workflows/*.yaml
actionlint "${actionlint_args[@]}" "$tmp_dir/.github/workflows"/*.yaml
shellcheck "$repo_root/scripts/generate-caller-workflows.sh" "$repo_root/scripts/validate-workflows.sh"

if rg -n 'Claude PR Assistant|@claude|CLAUDE_' \
  "$repo_root/.github/workflows" \
  "$repo_root/templates" \
  "$repo_root/scripts/generate-caller-workflows.sh"; then
  echo "Found stale Claude code-review references." >&2
  exit 1
fi

echo "Workflow validation passed."
