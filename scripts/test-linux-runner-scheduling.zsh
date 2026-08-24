#!/bin/zsh
set -eu

export TRIPS_LINUX_TART_CONTROLLER_SOURCE_ONLY=1
export TRIPS_LINUX_TART_REPOSITORIES="jai/trips-api,jai/trips-frontend,jai/trips-ci"

source "${0:A:h}/trips-linux-tart-runner-controller.zsh"

if [[ -o pipefail ]]; then
  print -u2 -r -- "controller source must not enable pipefail globally"
  exit 1
fi
printf '%s' probe | base64url >/dev/null
if [[ -o pipefail ]]; then
  print -u2 -r -- "pipeline helpers must restore the caller's pipefail setting"
  exit 1
fi

typeset -g api_queued_at=""
typeset -g frontend_queued_at=""
typeset -g ci_queued_at=""
typeset production_repository_oldest_queued_job_timestamp="${functions[repository_oldest_queued_job_timestamp]}"

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

functions[repository_oldest_queued_job_timestamp]="$production_repository_oldest_queued_job_timestamp"

repository_workflow_runs() {
  local candidate="$1"
  case "$candidate" in
    jai/trips-api)
      print -r -- $'api-new\t2026-08-24T19:00:00Z'
      print -r -- $'api-old\t2026-08-23T18:00:00Z'
      ;;
    jai/trips-frontend)
      print -r -- $'frontend-run\t2026-08-24T18:00:00Z'
      ;;
  esac
}

workflow_run_oldest_queued_job_timestamp() {
  local candidate="$1" run_id="$2"
  case "${candidate}:${run_id}" in
    jai/trips-api:api-new) print -r -- 2026-08-24T19:00:01Z ;;
    jai/trips-api:api-old) print -r -- 2026-08-24T20:00:00Z ;;
    jai/trips-frontend:frontend-run) print -r -- 2026-08-24T18:00:01Z ;;
    *) return 1 ;;
  esac
}

[[ "$(repository_oldest_queued_job_timestamp jai/trips-api)" == 2026-08-24T19:00:01Z ]]
[[ "$(repository_oldest_queued_job_timestamp jai/trips-frontend)" == 2026-08-24T18:00:01Z ]]
[[ -z "$(repository_oldest_queued_job_timestamp jai/trips-ci || true)" ]]

repository_workflow_runs() {
  return 2
}
if repository_oldest_queued_job_timestamp jai/trips-api; then
  print -u2 -r -- "expected repository lookup to preserve API failure"
  exit 1
else
  [[ $? -eq 2 ]]
fi
if next_repository; then
  print -u2 -r -- "expected scheduler to preserve API failure"
  exit 1
else
  [[ $? -eq 2 ]]
fi

print -r -- "linux runner scheduling tests passed"
