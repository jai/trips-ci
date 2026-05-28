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
case "${1:-}" in
  --check)
    mode="check"
    shift
    ;;
  --stdout)
    mode="stdout"
    shift
    ;;
esac

if [[ "$#" -gt 0 ]]; then
  TARGETS=("$@")
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

is_jai_only_target() {
  local target_name
  target_name="$(basename "$1")"
  [[ "$target_name" == "trips-fastlane" || "$target_name" == trips-fastlane-* || "$target_name" == "fastlane" ]]
}

render_workflow() {
  local target="$1"

  if ! is_jai_only_target "$target"; then
    cat "$TEMPLATE"
    return
  fi

  awk '
    {
      print
      if ($0 == "    name: Codex review router") {
        print "    if: >-"
        print "      ("
        print "        github.event_name == '\''pull_request'\'' &&"
        print "        github.event.pull_request.user.login == '\''jai'\''"
        print "      ) ||"
        print "      ("
        print "        github.event_name == '\''issue_comment'\'' &&"
        print "        github.event.issue.pull_request &&"
        print "        github.event.issue.user.login == '\''jai'\'' &&"
        print "        github.event.comment.user.login == '\''jai'\''"
        print "      ) ||"
        print "      ("
        print "        github.event_name == '\''pull_request_review_comment'\'' &&"
        print "        github.event.pull_request.user.login == '\''jai'\'' &&"
        print "        github.event.comment.user.login == '\''jai'\''"
        print "      )"
      }
    }
  ' "$TEMPLATE"
}

if [[ "$mode" == "stdout" ]]; then
  if [[ "${#TARGETS[@]}" -ne 1 ]]; then
    echo "--stdout expects exactly one target" >&2
    exit 2
  fi
  render_workflow "${TARGETS[0]}"
  exit 0
fi

for target in "${TARGETS[@]}"; do
  repo_dir="$target"
  workflow_path="$repo_dir/.github/workflows/code-review.yaml"

  if [[ "$mode" == "check" ]]; then
    if ! cmp -s <(render_workflow "$repo_dir") "$workflow_path"; then
      echo "Out of date: $workflow_path" >&2
      diff -u <(render_workflow "$repo_dir") "$workflow_path" || true
      exit 1
    fi
    echo "Current: $workflow_path"
  else
    mkdir -p "$(dirname "$workflow_path")"
    render_workflow "$repo_dir" > "$workflow_path"
    echo "Wrote: $workflow_path"
  fi

done
