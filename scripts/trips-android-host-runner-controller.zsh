#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly repository="${TRIPS_ANDROID_REPOSITORY:-jai/trips-frontend}"
readonly host_label="${TRIPS_ANDROID_HOST_LABEL:-borg-cube-03}"
readonly runner_root="${TRIPS_ANDROID_RUNNER_ROOT:-/Users/jai/.local/share/trips-android-host-runner/actions-runner}"
readonly work_root="${TRIPS_ANDROID_WORK_ROOT:-/Volumes/RunnerWork/android-host-jobs}"
readonly sdk_root="${TRIPS_ANDROID_SDK_ROOT:-/Volumes/RunnerWork/android-sdk}"
readonly avd_root="${TRIPS_ANDROID_AVD_ROOT:-/Volumes/RunnerWork/android-user/avd}"
readonly work_volume="${TRIPS_ANDROID_WORK_VOLUME:-/Volumes/RunnerWork}"
readonly lock_path="${TRIPS_ANDROID_NATIVE_LANE_LOCK:-/Users/jai/Library/Logs/trips-tart-native-lane.lock}"
readonly controller_lock="${TRIPS_ANDROID_CONTROLLER_LOCK:-/Users/jai/Library/Logs/trips-android-host-runner/controller.lock}"
readonly gh_cli="${TRIPS_ANDROID_GH_CLI:-/opt/homebrew/bin/gh}"
readonly shlock_cli="${TRIPS_ANDROID_SHLOCK_CLI:-/usr/bin/shlock}"
readonly pgrep_cli="${TRIPS_ANDROID_PGREP_CLI:-/usr/bin/pgrep}"
readonly mount_cli="${TRIPS_ANDROID_MOUNT_CLI:-/sbin/mount}"
readonly minimum_free_gib="${TRIPS_ANDROID_MINIMUM_FREE_GIB:-5}"
readonly claim_timeout_seconds="${TRIPS_ANDROID_CLAIM_TIMEOUT_SECONDS:-300}"
readonly claim_poll_seconds="${TRIPS_ANDROID_CLAIM_POLL_SECONDS:-2}"
readonly termination_grace_seconds="${TRIPS_ANDROID_TERMINATION_GRACE_SECONDS:-10}"

typeset -g native_lock_owned=false
typeset -g active_runner_pid=""
typeset -g active_runner_name=""
typeset -g active_job_root=""

log() { print -r -- "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }
acquire_lock() { "$shlock_cli" -f "$1" -p $$; }
release_lock() {
  local path="$1" owner=""
  [[ -r "$path" ]] && read -r owner <"$path"
  [[ "$owner" != $$ ]] || /bin/rm -f "$path"
}

release_native_lane() {
  [[ "$native_lock_owned" == true ]] || return 0
  release_lock "$lock_path" || return 1
  native_lock_owned=false
}

android_preflight() {
  [[ "$(scutil --get ComputerName)" == "$host_label" ]] || return 1
  work_volume_mounted || return 1
  [[ "$(df -g / | awk 'NR == 2 { print $4 }')" -ge "$minimum_free_gib" ]] || return 1
  [[ "$(df -g "$work_root" | awk 'NR == 2 { print $4 }')" -ge "$minimum_free_gib" ]] || return 1
  [[ -x "$runner_root/bin/Runner.Listener" ]] || return 1
  [[ -x "$sdk_root/emulator/emulator" && -x "$sdk_root/platform-tools/adb" ]] || return 1
  java -version >/dev/null 2>&1 || return 1
  emulator_acceleration_healthy || return 1
  ANDROID_SDK_ROOT="$sdk_root" ANDROID_AVD_HOME="$avd_root" \
    "$sdk_root/emulator/emulator" -list-avds | grep -qx ci-android-arm64
}

work_volume_mounted() {
  [[ "$work_root" == "$work_volume"/* ]] || return 1
  "$mount_cli" | grep -Fq " on ${work_volume} ("
}

emulator_acceleration_healthy() {
  local acceleration_output
  acceleration_output=$("$sdk_root/emulator/emulator" -accel-check 2>&1) || return 1
  print -r -- "$acceleration_output" | awk '
    NR == 1 && /^accel:$/ { header = 1 }
    NR == 2 && /^0$/ { status = 1 }
    NR == 3 && /^Hypervisor\.Framework OS X Version [0-9.]+$/ { hypervisor = 1 }
    NR == 4 && /^accel$/ { summary = 1 }
    NR > 4 { unexpected = 1 }
    END { exit !(NR == 4 && header && status && hypervisor && summary && !unexpected) }
  '
}

queued_android_job_exists() {
  local run_status run_ids run_id queued_labels
  for run_status in queued in_progress; do
    run_ids=$("$gh_cli" api --paginate "repos/${repository}/actions/runs?status=${run_status}&per_page=100" --jq '.workflow_runs[].id') || return 1
    while IFS= read -r run_id; do
      [[ -n "$run_id" ]] || continue
      queued_labels=$("$gh_cli" api --paginate "repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" --jq '
        .jobs[] | select(.status == "queued") | [.labels[] | ascii_downcase] |
        if (index("self-hosted") and index("macos") and index("arm64") and index("android") and index("borg-cube-03")) then "yes" else empty end
      ') || return 1
      grep -qx yes <<<"$queued_labels" && return 0
    done <<<"$run_ids"
  done
  return 1
}

delete_runner_registration() {
  local runner_name="$1" runner_id
  runner_id=$("$gh_cli" api --paginate "repos/${repository}/actions/runners?per_page=100" --jq --arg name "$runner_name" '.runners[]? | select(.name == $name) | .id') || return 1
  [[ -n "$runner_id" ]] || return 0
  "$gh_cli" api -X DELETE "repos/${repository}/actions/runners/${runner_id}" >/dev/null
}

runner_process_running() {
  kill -0 "$1" 2>/dev/null && /bin/ps -o stat= -p "$1" 2>/dev/null | grep -qv '^[[:space:]]*Z'
}

runner_worker_claimed() {
  "$pgrep_cli" -f "$1/runner/bin/Runner.Worker" >/dev/null 2>&1
}

wait_for_runner_claim() {
  local runner_pid="$1" job_root="$2" deadline
  deadline=$((SECONDS + claim_timeout_seconds))
  while runner_process_running "$runner_pid"; do
    runner_worker_claimed "$job_root" && return 0
    (( SECONDS >= deadline )) && return 2
    sleep "$claim_poll_seconds"
  done
  return 1
}

wait_for_runner_exit() {
  local runner_pid="$1" deadline
  deadline=$((SECONDS + termination_grace_seconds))
  while runner_process_running "$runner_pid"; do
    (( SECONDS >= deadline )) && return 1
    sleep 1
  done
}

terminate_runner_process() {
  local runner_pid="$1" child_pid
  [[ -n "$runner_pid" ]] || return 0
  while IFS= read -r child_pid; do
    [[ -n "$child_pid" ]] || continue
    terminate_runner_process "$child_pid"
  done < <("$pgrep_cli" -P "$runner_pid" 2>/dev/null || true)
  runner_process_running "$runner_pid" || return 0
  kill -TERM "$runner_pid" 2>/dev/null || return 1
  wait_for_runner_exit "$runner_pid" && return 0
  kill -KILL "$runner_pid" 2>/dev/null || return 1
  wait_for_runner_exit "$runner_pid"
}

clear_active_runner() {
  active_runner_pid=""
  active_runner_name=""
  active_job_root=""
}

cleanup_active_runner() {
  [[ -z "$active_runner_pid" ]] || terminate_runner_process "$active_runner_pid" || return 1
  [[ -z "$active_runner_name" ]] || delete_runner_registration "$active_runner_name" || return 1
  [[ -z "$active_job_root" ]] || /bin/rm -rf -- "$active_job_root" || return 1
  clear_active_runner
}

run_one_job() {
  local suffix job_root runner_name token runner_pid runner_status claim_status
  suffix="$(date -u '+%Y%m%d%H%M%S')-$$"
  job_root="${work_root}/job-${suffix}"
  runner_name="${host_label}-android-${suffix}"
  mkdir -p "$job_root/tmp" "$job_root/npm" "$job_root/gradle" "$job_root/work"
  [[ -w "$job_root/tmp" && -w "$job_root/npm" && -w "$job_root/gradle" && -w "$job_root/work" ]] || {
    /bin/rm -rf -- "$job_root"
    return 1
  }
  /bin/cp -R "$runner_root" "$job_root/runner" || {
    /bin/rm -rf -- "$job_root"
    return 1
  }
  token=$("$gh_cli" api -X POST "repos/${repository}/actions/runners/registration-token" --jq .token) || {
    /bin/rm -rf -- "$job_root"
    return 1
  }
  print -r -- "$token" | (
    cd "$job_root/runner" || exit 1
    IFS= read -r token
    export TMPDIR="$job_root/tmp" npm_config_cache="$job_root/npm" GRADLE_USER_HOME="$job_root/gradle"
    export ANDROID_SDK_ROOT="$sdk_root" ANDROID_HOME="$sdk_root" ANDROID_AVD_HOME="$avd_root" ANDROID_USER_HOME="${avd_root:h}"
    ./config.sh --unattended --ephemeral --disableupdate --url "https://github.com/${repository}" --token "$token" --name "$runner_name" --labels "${host_label},android" --work "$job_root/work" || exit $?
    ./run.sh
  ) &
  runner_pid=$!
  active_runner_pid="$runner_pid"
  active_runner_name="$runner_name"
  active_job_root="$job_root"
  if wait_for_runner_claim "$runner_pid" "$job_root"; then
    if wait "$runner_pid"; then
      runner_status=0
    else
      runner_status=$?
    fi
  else
    claim_status=$?
    log "Android runner did not claim a job (status ${claim_status}); terminating it"
    runner_status="$claim_status"
  fi
  cleanup_active_runner || return 1
  return "$runner_status"
}

cleanup_and_release() {
  if cleanup_active_runner; then
    release_native_lane
  else
    log 'Android runner cleanup failed; retaining the shared native lane lock'
  fi
  release_lock "$controller_lock" || true
}

main() {
  mkdir -p "${controller_lock:h}"
  acquire_lock "$controller_lock" || return 1
  trap 'cleanup_and_release' EXIT
  trap 'exit 143' INT TERM
  "$gh_cli" auth status >/dev/null 2>&1 || return 1
  while true; do
    work_volume_mounted || { log 'Android external work volume is not mounted; refusing runner registration'; sleep 30; continue; }
    queued_android_job_exists || { sleep 30; continue; }
    acquire_lock "$lock_path" || { sleep 15; continue; }
    native_lock_owned=true
    if ! android_preflight; then
      log 'Android host preflight failed; refusing runner registration'
      release_native_lane
      sleep 30
      continue
    fi
    if ! run_one_job; then
      log 'Android one-job runner failed'
      [[ -z "$active_runner_pid$active_runner_name$active_job_root" ]] || return 1
    fi
    release_native_lane
  done
}

[[ "${TRIPS_ANDROID_CONTROLLER_LIBRARY_ONLY:-false}" == true ]] || main "$@"
