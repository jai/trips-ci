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
    acquire_priority_lock() { return 0; }
    release_priority_lock() { return 0; }
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
    shared_lane_has_ephemeral_vm() { return 1; }
    typeset -g lane_released=false
    release_lane_lock() { lane_released=true; }
    acquire_linux_lane && exit 1
    [[ $? == 2 ]]
    [[ "$lane_released" == true ]]

    wait_for_runner_shutdown() { return 1; }
    runner_process_state() { print worker; }
    typeset -g cleanup_allowed=true
    ! supervise_claimed_runner 192.0.2.1
    [[ "$cleanup_allowed" == false ]]

    vm_list=$(printf "base\ntrips-linux-runner-job-test\n")
    set +e
    clone_artifact_result trips-linux-runner-job-test 0 "$vm_list"; result=$?
    [[ $result == 3 ]]
    clone_artifact_result trips-linux-runner-job-other 0 "$vm_list"; result=$?
    [[ $result == 1 ]]
    clone_artifact_result trips-linux-runner-job-test 1 ""; result=$?
    [[ $result == 3 ]]
    set -e

    acquire_lane_lock() { return 0; }
    shared_lane_has_ephemeral_vm() { return 0; }
    lane_released=false
    ! acquire_clean_lane_lock
    [[ "$lane_released" == true ]]
  ' _ "$repository_root"

TRIPS_RUNNER_CONTROLLER_TEST_MODE=true \
TRIPS_TART_NATIVE_PRIORITY_FILE="${scratch_directory}/native-priority" \
  /bin/zsh -c '
    set -euo pipefail
    source "$1/scripts/trips-tart-runner-controller.zsh"
    acquire_priority_lock() { return 0; }
    release_priority_lock() { return 0; }
    request_native_lane_priority
    [[ "$(<"$TRIPS_TART_NATIVE_PRIORITY_FILE")" == $$ ]]
    release_native_lane_priority
    [[ ! -e "$TRIPS_TART_NATIVE_PRIORITY_FILE" ]]

    stop_idle_listener() { print draining; }
    runner_process_state() { print absent; }
    sleep() { return 0; }
    [[ "$(reconcile_stale_runner_state 192.0.2.1 listener)" == absent ]]
    [[ "$(reconcile_stale_runner_state 192.0.2.1 worker)" == worker ]]

    wait_for_runner_shutdown() { return 1; }
    runner_process_state() { print worker; }
    typeset -g cleanup_allowed=true
    ! supervise_claimed_runner 192.0.2.1
    [[ "$cleanup_allowed" == false ]]

    vm_list=$(printf "base\ntrips-runner-job-test\n")
    set +e
    clone_artifact_result trips-runner-job-test 0 "$vm_list"; result=$?
    [[ $result == 3 ]]
    clone_artifact_result trips-runner-job-other 0 "$vm_list"; result=$?
    [[ $result == 1 ]]
    clone_artifact_result trips-runner-job-test 1 ""; result=$?
    [[ $result == 3 ]]
    set -e

    github_user_api() {
      local endpoint="$1"
      if [[ "$endpoint" == *"actions/runs?status=queued"* ]]; then
        print "{\"workflow_runs\":[]}"
      elif [[ "$endpoint" == *"actions/runs?status=in_progress"* ]]; then
        print "{\"workflow_runs\":[{\"id\":42}]}"
      else
        print "{\"jobs\":[{\"status\":\"queued\",\"labels\":[\"self-hosted\",\"macOS\",\"ARM64\",\"tart\",\"ios\"]}]}"
      fi
    }
    repository_has_queued_native_job

    github_user_api() {
      local endpoint="$1"
      if [[ "$endpoint" == *"actions/runs?status=queued"* ]]; then
        print "{\"workflow_runs\":[{\"id\":44}]}"
      elif [[ "$endpoint" == *"actions/runs?status=in_progress"* ]]; then
        print "{\"workflow_runs\":[]}"
      else
        print "{\"jobs\":[{\"status\":\"queued\",\"labels\":[\"self-hosted\",\"macOS\",\"ARM64\",\"tart\",\"ios\",\"other-host\"]}]}"
      fi
    }
    ! repository_has_queued_native_job

    github_user_api() {
      local endpoint="$1"
      if [[ "$endpoint" == *"actions/runs?status=queued"* ]]; then
        print "{\"workflow_runs\":[{\"id\":43}]}"
      elif [[ "$endpoint" == *"actions/runs?status=in_progress"* ]]; then
        print "{\"workflow_runs\":[]}"
      else
        print "{\"jobs\":[{\"status\":\"queued\",\"labels\":[\"self-hosted\",\"linux\",\"arm64\",\"jai-ci\"]}]}"
      fi
    }
    ! repository_has_queued_native_job

    typeset -g github_installation_token="expired"
    ensure_installation_token() { github_installation_token="fresh"; }
    registration_token() { [[ "$1" == fresh ]] && print runner-token; }
    ensure_installation_token
    token=$(registration_token "$github_installation_token")
    [[ "$github_installation_token" == fresh ]]
    [[ "$token" == runner-token ]]
  ' _ "$repository_root"

print "runner controller native-priority tests passed"
