#!/bin/zsh
set -eu

export TRIPS_LINUX_TART_CONTROLLER_SOURCE_ONLY=1
export TRIPS_LINUX_TART_REPOSITORIES="jai/trips-api,jai/trips-frontend,jai/trips-ci"

source "${0:A:h}/trips-linux-tart-runner-controller.zsh"

typeset -ga queued_repositories

repository_has_queued_job() {
  local candidate="$1"
  (( ${queued_repositories[(Ie)$candidate]} > 0 ))
}

assert_selected() {
  local expected="$1"
  next_repository
  if [[ "$selected_repository" != "$expected" ]]; then
    print -u2 -r -- "expected ${expected}, selected ${selected_repository}"
    return 1
  fi
}

queued_repositories=(jai/trips-api jai/trips-frontend)
assert_selected jai/trips-api
assert_selected jai/trips-frontend
assert_selected jai/trips-api

queued_repositories=(jai/trips-frontend)
assert_selected jai/trips-frontend

queued_repositories=(jai/trips-api jai/trips-frontend jai/trips-ci)
assert_selected jai/trips-ci
assert_selected jai/trips-api
assert_selected jai/trips-frontend

queued_repositories=()
if next_repository; then
  print -u2 -r -- "expected no repository, selected ${selected_repository}"
  exit 1
fi
[[ -z "$selected_repository" ]]

print -r -- "linux runner scheduling tests passed"
