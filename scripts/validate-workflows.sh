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
  -ignore 'label "jai-ci" is unknown'
)

actionlint "${actionlint_args[@]}" "$repo_root"/.github/workflows/*.yaml "$repo_root"/.github/workflows/*.yml
actionlint "${actionlint_args[@]}" "$tmp_dir/.github/workflows"/*.yaml
actionlint "${actionlint_args[@]}" "$repo_root"/templates/*.yaml
shellcheck "$repo_root/scripts/generate-caller-workflows.sh" "$repo_root/scripts/validate-workflows.sh"
shellcheck "$repo_root/scripts/provision-lima-runner-base.sh"
zsh -n \
  "$repo_root/scripts/provision-lima-runner-base.zsh" \
  "$repo_root/scripts/provision-tart-runner-base.zsh" \
  "$repo_root/scripts/start-trips-linux-lima-runner.zsh" \
  "$repo_root/scripts/start-trips-tart-runner.zsh" \
  "$repo_root/scripts/trips-linux-lima-runner-controller.zsh" \
  "$repo_root/scripts/trips-tart-runner-controller.zsh" \
  "$repo_root/tests/trips-linux-lima-runner-controller-test.zsh" \
  "$repo_root/tests/provision-tart-runner-base-test.zsh" \
  "$repo_root/tests/trips-tart-runner-controller-test.zsh"
"$repo_root/tests/trips-linux-lima-runner-controller-test.zsh"
"$repo_root/tests/provision-tart-runner-base-test.zsh"
"$repo_root/tests/trips-tart-runner-controller-test.zsh"
plist_files=(
  "$repo_root/launchd/com.jai.trips-linux-lima-runner-a.plist"
  "$repo_root/launchd/com.jai.trips-linux-lima-runner-b.plist"
  "$repo_root/launchd/com.jai.trips-tart-runner.plist"
)
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "${plist_files[@]}"
else
  python3 - "${plist_files[@]}" <<'PY'
import plistlib
import sys

for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        plistlib.load(handle)
    print(f"{path}: OK")
PY
fi

if rg -n 'Claude PR Assistant|@claude|CLAUDE_' \
  "$repo_root/.github/workflows" \
  "$repo_root/templates" \
  "$repo_root/scripts/generate-caller-workflows.sh"; then
  echo "Found stale Claude code-review references." >&2
  exit 1
fi

echo "Workflow validation passed."
