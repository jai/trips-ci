#!/bin/zsh
set -eu

export TRIPS_LINUX_TART_CONTROLLER_SOURCE_ONLY=1
export TRIPS_LINUX_TART_REPOSITORIES="jai/trips-api,jai/trips-frontend,jai/trips-ci"

source "${0:A:h}/trips-linux-tart-runner-controller.zsh"

typeset -g api_queued_at=""
typeset -g frontend_queued_at=""
typeset -g ci_queued_at=""

repository_oldest_queued_job_timestamp() {
  local candidate="$1"
  case "$candidate" in
    jai/trips-api) [[ -n "$api_queued_at" ]] && print -r -- "$api_queued_at" ;;
    jai/trips-frontend) [[ -n "$frontend_queued_at" ]] && print -r -- "$frontend_queued_at" ;;
    jai/trips-ci) [[ -n "$ci_queued_at" ]] && print -r -- "$ci_queued_at" ;;
    *) return 1 ;;
  esac
}

assert_selected() {
  local expected="$1"
  if ! next_repository; then
    print -u2 -r -- "expected ${expected}, selected no repository"
    return 1
  fi
  if [[ "$selected_repository" != "$expected" ]]; then
    print -u2 -r -- "expected ${expected}, selected ${selected_repository}"
    return 1
  fi
}

api_queued_at=2026-08-24T19:00:00Z
frontend_queued_at=2026-08-24T18:00:00Z
ci_queued_at=""
assert_selected jai/trips-frontend

api_queued_at=""
frontend_queued_at=2026-08-24T18:00:00Z
assert_selected jai/trips-frontend

api_queued_at=2026-08-24T18:00:00Z
frontend_queued_at=2026-08-24T18:00:00Z
ci_queued_at=2026-08-24T18:00:00Z
assert_selected jai/trips-api

api_queued_at=""
frontend_queued_at=""
ci_queued_at=""
if next_repository; then
  print -u2 -r -- "expected no repository, selected ${selected_repository}"
  exit 1
fi
[[ -z "$selected_repository" ]]

print -r -- "linux runner scheduling tests passed"
