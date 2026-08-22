#!/bin/zsh
set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly scratch_directory="$(mktemp -d "${repository_root}/tmp.runner-priority.XXXXXX")"
trap '/bin/rm -rf "$scratch_directory"' EXIT

TRIPS_RUNNER_CONTROLLER_TEST_MODE=true \
TRIPS_TART_NATIVE_PRIORITY_FILE="${scratch_directory}/native-priority" \
TRIPS_TART_LANE_POLL_SECONDS=0 \
  /bin/zsh -c '
    set -euo pipefail
    source "$1/scripts/trips-linux-tart-runner-controller.zsh"
    printf "%s\n" $$ >"$TRIPS_TART_NATIVE_PRIORITY_FILE"
    native_lane_priority_requested
    printf "%s\n" 999999 >"$TRIPS_TART_NATIVE_PRIORITY_FILE"
    ! native_lane_priority_requested
    [[ ! -e "$TRIPS_TART_NATIVE_PRIORITY_FILE" ]]

    typeset -g lane_acquire_calls=0
    acquire_lane_lock() {
      (( lane_acquire_calls += 1 ))
      if (( lane_acquire_calls == 1 )); then
        return 1
      fi
      printf "%s\n" $$ >"$TRIPS_TART_NATIVE_PRIORITY_FILE"
      return 0
    }
    typeset -g lane_released=false
    release_lane_lock() { lane_released=true; }
    acquire_linux_lane && exit 1
    [[ $? == 2 ]]
    [[ "$lane_released" == true ]]
  ' _ "$repository_root"

TRIPS_RUNNER_CONTROLLER_TEST_MODE=true \
TRIPS_TART_NATIVE_PRIORITY_FILE="${scratch_directory}/native-priority" \
  /bin/zsh -c '
    set -euo pipefail
    source "$1/scripts/trips-tart-runner-controller.zsh"
    request_native_lane_priority
    [[ "$(<"$TRIPS_TART_NATIVE_PRIORITY_FILE")" == $$ ]]
    release_native_lane_priority
    [[ ! -e "$TRIPS_TART_NATIVE_PRIORITY_FILE" ]]

    github_api() {
      local method="$1" endpoint="$2"
      if [[ "$endpoint" == *"actions/runs?status=queued"* ]]; then
        print "{\"workflow_runs\":[]}"
      elif [[ "$endpoint" == *"actions/runs?status=in_progress"* ]]; then
        print "{\"workflow_runs\":[{\"id\":42}]}"
      else
        print "{\"jobs\":[{\"status\":\"queued\",\"labels\":[\"self-hosted\",\"macOS\",\"ARM64\",\"tart\",\"ios\"]}]}"
      fi
    }
    repository_has_queued_native_job

    github_api() {
      local method="$1" endpoint="$2"
      if [[ "$endpoint" == *"actions/runs?status=queued"* ]]; then
        print "{\"workflow_runs\":[{\"id\":43}]}"
      elif [[ "$endpoint" == *"actions/runs?status=in_progress"* ]]; then
        print "{\"workflow_runs\":[]}"
      else
        print "{\"jobs\":[{\"status\":\"queued\",\"labels\":[\"self-hosted\",\"linux\",\"arm64\",\"jai-ci\"]}]}"
      fi
    }
    ! repository_has_queued_native_job
  ' _ "$repository_root"

print "runner controller native-priority tests passed"
