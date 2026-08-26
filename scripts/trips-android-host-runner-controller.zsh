#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly repository="${TRIPS_ANDROID_REPOSITORY:-jai/trips-frontend}"
readonly host_label="${TRIPS_ANDROID_HOST_LABEL:-borg-cube-03}"
readonly runner_root="${TRIPS_ANDROID_RUNNER_ROOT:-/Users/jai/.local/share/trips-android-host-runner/actions-runner}"
readonly work_root="${TRIPS_ANDROID_WORK_ROOT:-/Volumes/RunnerWork/android-host-jobs}"
readonly sdk_root="${TRIPS_ANDROID_SDK_ROOT:-/Volumes/RunnerWork/android-sdk}"
readonly avd_root="${TRIPS_ANDROID_AVD_ROOT:-/Volumes/RunnerWork/android-user/avd}"
readonly lock_path="${TRIPS_ANDROID_NATIVE_LANE_LOCK:-/Users/jai/Library/Logs/trips-tart-native-lane.lock}"
readonly controller_lock="${TRIPS_ANDROID_CONTROLLER_LOCK:-/Users/jai/Library/Logs/trips-android-host-runner/controller.lock}"
readonly gh_cli="${TRIPS_ANDROID_GH_CLI:-/opt/homebrew/bin/gh}"
readonly shlock_cli="${TRIPS_ANDROID_SHLOCK_CLI:-/usr/bin/shlock}"
readonly minimum_free_gib="${TRIPS_ANDROID_MINIMUM_FREE_GIB:-5}"

typeset -g native_lock_owned=false

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
  [[ "$(df -g / | awk 'NR == 2 { print $4 }')" -ge "$minimum_free_gib" ]] || return 1
  [[ "$(df -g "$work_root" | awk 'NR == 2 { print $4 }')" -ge "$minimum_free_gib" ]] || return 1
  [[ -x "$runner_root/bin/Runner.Listener" ]] || return 1
  [[ -x "$sdk_root/emulator/emulator" && -x "$sdk_root/platform-tools/adb" ]] || return 1
  java -version >/dev/null 2>&1 || return 1
  emulator_acceleration_healthy || return 1
  ANDROID_SDK_ROOT="$sdk_root" ANDROID_AVD_HOME="$avd_root" \
    "$sdk_root/emulator/emulator" -list-avds | grep -qx ci-android-arm64
}

emulator_acceleration_healthy() {
  "$sdk_root/emulator/emulator" -accel-check 2>&1 | awk '
    /^accel: 0$/ { status = 1 }
    /is installed and usable/ { usable = 1 }
    END { exit !(status && usable) }
  '
}

queued_android_job_exists() {
  local run_ids run_id queued_labels
  run_ids=$("$gh_cli" api --paginate "repos/${repository}/actions/runs?status=queued&per_page=100" --jq '.workflow_runs[].id') || return 1
  [[ -n "${run_ids//[[:space:]]/}" ]] || return 1
  while IFS= read -r run_id; do
    [[ -n "$run_id" ]] || continue
    queued_labels=$("$gh_cli" api --paginate "repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" --jq '
      .jobs[] | select(.status == "queued") | [.labels[] | ascii_downcase] |
      if (index("self-hosted") and index("macos") and index("arm64") and index("android") and index("borg-cube-03")) then "yes" else empty end
    ') || return 1
    grep -qx yes <<<"$queued_labels" && return 0
  done <<<"$run_ids"
  return 1
}

delete_runner_registration() {
  local runner_name="$1" runner_id
  runner_id=$("$gh_cli" api --paginate "repos/${repository}/actions/runners?per_page=100" --jq --arg name "$runner_name" '.runners[]? | select(.name == $name) | .id') || return 1
  [[ -n "$runner_id" ]] || return 0
  "$gh_cli" api -X DELETE "repos/${repository}/actions/runners/${runner_id}" >/dev/null
}

run_one_job() {
  local suffix job_root runner_name token runner_pid runner_status cleanup_status=0
  suffix="$(date -u '+%Y%m%d%H%M%S')-$$"
  job_root="${work_root}/job-${suffix}"
  runner_name="${host_label}-android-${suffix}"
  mkdir -p "$job_root"
  ditto "$runner_root" "$job_root/runner" || {
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
  if wait "$runner_pid"; then
    runner_status=0
  else
    runner_status=$?
  fi
  delete_runner_registration "$runner_name" || cleanup_status=$?
  /bin/rm -rf -- "$job_root"
  (( cleanup_status == 0 )) || return "$cleanup_status"
  return "$runner_status"
}

main() {
  mkdir -p "${controller_lock:h}" "$work_root"
  acquire_lock "$controller_lock" || return 1
  trap 'release_native_lane; release_lock "$controller_lock"' EXIT
  "$gh_cli" auth status >/dev/null 2>&1 || return 1
  while true; do
    queued_android_job_exists || { sleep 30; continue; }
    acquire_lock "$lock_path" || { sleep 15; continue; }
    native_lock_owned=true
    if ! android_preflight; then
      log 'Android host preflight failed; refusing runner registration'
      release_native_lane
      sleep 30
      continue
    fi
    run_one_job || log 'Android one-job runner failed'
    release_native_lane
  done
}

[[ "${TRIPS_ANDROID_CONTROLLER_LIBRARY_ONLY:-false}" == true ]] || main "$@"
