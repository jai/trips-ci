#!/bin/zsh
set -eu

repo_root="${0:A:h:h}"
mkdir -p "${repo_root}/tmp"
test_directory=$(mktemp -d "${repo_root}/tmp/tart-controller-test.XXXXXX")
trap '/bin/rm -rf -- "$test_directory"' EXIT

fake_gh="${test_directory}/gh"
cat > "$fake_gh" <<'SCRIPT'
#!/bin/zsh
set -eu

request="$*"
case "${FAKE_SCENARIO:-}" in
  tonegate-only)
    if [[ "$request" == *'repos/jai/tonegate/actions/runs?'* ]]; then
      print -r -- $'101\t2026-08-25T00:00:00Z\tjai/tonegate'
    elif [[ "$request" == *'repos/jai/tonegate/actions/runs/101/jobs?'* ]]; then
      print -r -- '[{"jobs":[{"status":"queued","created_at":"2026-08-25T00:00:01Z","labels":["self-hosted","macOS","ARM64","tart","ios"]}]}]'
    fi
    ;;
  trips-first)
    if [[ "$request" == *'repos/jai/trips-frontend/actions/runs?'* ]]; then
      print -r -- $'202\t2026-08-25T00:00:00Z\tjai/trips-frontend'
    elif [[ "$request" == *'repos/jai/trips-frontend/actions/runs/202/jobs?'* ]]; then
      print -r -- '[{"jobs":[{"status":"queued","created_at":"2026-08-25T00:00:02Z","labels":["self-hosted","macOS","ARM64","tart","ios"]}]}]'
    fi
    ;;
  incompatible-host)
    if [[ "$request" == *'repos/jai/trips-frontend/actions/runs?'* ]]; then
      print -r -- $'303\t2026-08-25T00:00:00Z\tjai/trips-frontend'
    elif [[ "$request" == *'repos/jai/trips-frontend/actions/runs/303/jobs?'* ]]; then
      print -r -- '[{"jobs":[{"status":"queued","created_at":"2026-08-25T00:00:03Z","labels":["self-hosted","macOS","ARM64","tart","ios","borg-cube-03"]}]}]'
    fi
    ;;
  no-jobs)
    if [[ "$request" == *'repos/jai/trips-frontend/actions/runs?'* ]]; then
      print -r -- $'202\t2026-08-25T00:00:00Z\tjai/trips-frontend'
    elif [[ "$request" == *'repos/jai/trips-frontend/actions/runs/202/jobs?'* ]]; then
      print -r -- '[{"jobs":[]}]'
    fi
    ;;
  *)
    print -u2 -- "Unknown fake scenario"
    exit 1
    ;;
esac
SCRIPT
chmod 700 "$fake_gh"

fake_curl="${test_directory}/curl"
cat > "$fake_curl" <<'SCRIPT'
#!/bin/zsh
set -eu
request="$*"
if [[ "$request" == *'actions/runners?per_page=100&page=1'* ]]; then
  /usr/bin/python3 -c 'import json; print(json.dumps({"runners":[{"id":i,"name":f"other-{i}","busy":False} for i in range(100)]}))'
elif [[ "$request" == *'actions/runners?per_page=100&page=2'* ]]; then
  print -r -- '{"runners":[{"id":4343,"name":"page-two-runner","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"},{"name":"ARM64"},{"name":"tart"},{"name":"ios"}]}]}'
else
  print -u2 -- "Unexpected curl request: ${request}"
  exit 1
fi
SCRIPT
chmod 700 "$fake_curl"

fake_tart="${test_directory}/tart"
cat > "$fake_tart" <<'SCRIPT'
#!/bin/zsh
set -eu
if [[ -n "${FAKE_TART_RUN_LOG:-}" ]]; then
  print -r -- "$*" >> "$FAKE_TART_RUN_LOG"
fi
if [[ "$1" == list && "${FAKE_VM_INVENTORY_ERROR:-false}" == true ]]; then
  exit 42
fi
if [[ "$1" == list && "$*" == *'--format json'* ]]; then
  FAKE_RUNNING_VM="${FAKE_RUNNING_VM:-}" FAKE_EPHEMERAL_STATE="${FAKE_EPHEMERAL_STATE:-}" /usr/bin/python3 -c 'import json,os
vms=[{"Name":"trips-runner-base","Running":False,"State":"stopped","Source":"local"}]
running=os.environ["FAKE_RUNNING_VM"]
state=os.environ["FAKE_EPHEMERAL_STATE"]
if running:
    vms.append({"Name":running,"Running":True,"State":"running","Source":"local"})
if state:
    vms.append({"Name":"trips-runner-job-stale","Running":state == "running","State":state,"Source":"local"})
print(json.dumps(vms))'
elif [[ "$1" == list && "${FAKE_VM_PRESENT:-false}" == true ]]; then
  print -r -- 'test-vm'
elif [[ "$1" == list && "${FAKE_STALE_VM_PRESENT:-false}" == true ]]; then
  print -r -- 'trips-runner-job-stale'
fi
exit 0
SCRIPT
chmod 700 "$fake_tart"

fake_shlock="${test_directory}/shlock"
cat > "$fake_shlock" <<'SCRIPT'
#!/bin/zsh
set -eu

lock_file=""
owner_pid=""
while (( $# > 0 )); do
  case "$1" in
    -f) lock_file="$2"; shift 2 ;;
    -p) owner_pid="$2"; shift 2 ;;
    *) exit 64 ;;
  esac
done
[[ -n "$lock_file" && -n "$owner_pid" ]] || exit 64
(setopt noclobber; print -r -- "$owner_pid" > "$lock_file") 2>/dev/null
SCRIPT
chmod 700 "$fake_shlock"

export TRIPS_RUNNER_CONTROLLER_LIBRARY_ONLY=true
export TRIPS_TART_GH_CLI="$fake_gh"
export TRIPS_TART_CURL_CLI="$fake_curl"
export TRIPS_TART_CLI="$fake_tart"
export TRIPS_TART_SHLOCK_CLI="$fake_shlock"
export TRIPS_TART_REPOSITORIES='jai/trips-frontend,jai/tonegate'
export TRIPS_TART_CLAIM_TIMEOUT_SECONDS=2
export TRIPS_TART_CLAIM_POLL_SECONDS=0.1
export TRIPS_TART_CONTROLLER_LOCK="${test_directory}/controller.lock"
export TRIPS_TART_NATIVE_LANE_LOCK="${test_directory}/native-lane.lock"
source "${repo_root}/scripts/trips-tart-runner-controller.zsh"
installation_token_value=test-token
installation_token_expires_at=4102444800

assert_equal() {
  local expected="$1" actual="$2"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 -- "Expected '$expected', got '$actual'"
    return 1
  fi
}

if runner_cycle_status 0 1; then
  print -u2 -- 'Expected cleanup failure to override a successful runner operation'
  exit 1
else
  assert_equal 1 "$?"
fi
if runner_cycle_status 2 0; then
  print -u2 -- 'Expected arbitrary runner exit status to normalize as failure'
  exit 1
else
  assert_equal 1 "$?"
fi

(exit 75) &
runner_pid=$!
resolve_runner_status 1 "$runner_pid" exit-75-runner
assert_equal 1 "$REPLY"
if runner_cycle_status "$REPLY" 0; then
  print -u2 -- 'Expected runner exit 75 to remain an ordinary runner failure'
  exit 1
else
  assert_equal 1 "$?"
fi

runner_cycle_status 0 0
if runner_cycle_status "$native_capacity_deferred_status" 0; then
  print -u2 -- 'Expected native-capacity deferral status to remain distinct'
  exit 1
else
  assert_equal "$native_capacity_deferred_status" "$?"
fi

native_capacity_reason=tonegate-search-20260825
REPLY=sentinel_installation_token
runner_cycle_log_message "$native_capacity_deferred_status" jai/trips-frontend
assert_equal 'waiting for exclusive native capacity before serving jai/trips-frontend: tonegate-search-20260825' "$REPLY"
[[ "$REPLY" != *sentinel_installation_token* ]]
REPLY=sentinel_installation_token
runner_cycle_log_message 2 jai/trips-frontend
assert_equal 'ephemeral runner cycle failed for jai/trips-frontend; retrying in 30 seconds' "$REPLY"
[[ "$REPLY" != *sentinel_installation_token* ]]

typeset production_release_lock="${functions[release_lock]}"
native_lane_lock_owned=true
native_lane_release_failed=false
release_lock() { return 7; }
if release_native_lane; then
  print -u2 -- 'Expected native-lane unlock failure to propagate'
  exit 1
else
  assert_equal 7 "$?"
fi
assert_equal true "$native_lane_lock_owned"
assert_equal true "$native_lane_release_failed"
functions[release_lock]="$production_release_lock"
native_lane_lock_owned=false
native_lane_release_failed=false

if [[ -o pipefail ]]; then
  print -u2 -- 'Controller source must not enable pipefail globally'
  exit 1
fi
printf '%s' probe | base64url >/dev/null
if [[ -o pipefail ]]; then
  print -u2 -- 'Pipeline helpers must restore the caller pipefail setting'
  exit 1
fi

export FAKE_SCENARIO=tonegate-only
assert_equal 2026-08-25T00:00:01Z "$(workflow_run_oldest_queued_job_timestamp jai/tonegate 101)"
export FAKE_SCENARIO=trips-first
assert_equal 2026-08-25T00:00:02Z "$(workflow_run_oldest_queued_job_timestamp jai/trips-frontend 202)"
export FAKE_SCENARIO=no-jobs
if workflow_run_oldest_queued_job_timestamp jai/trips-frontend 202 | /usr/bin/grep -q .; then
  print -u2 -- 'Expected no matching queued job'
  exit 1
fi

typeset production_repository_oldest_queued_job_timestamp="${functions[repository_oldest_queued_job_timestamp]}"
typeset -g frontend_queued_at=2026-08-25T00:03:00Z
typeset -g tonegate_queued_at=2026-08-25T00:01:00Z
repository_oldest_queued_job_timestamp() {
  local queued_at
  case "$1" in
    jai/trips-frontend) queued_at="$frontend_queued_at" ;;
    jai/tonegate) queued_at="$tonegate_queued_at" ;;
    *) return 1 ;;
  esac
  [[ -n "$queued_at" ]] || return 1
  print -r -- "$queued_at"
}
next_repository
assert_equal jai/tonegate "$selected_repository"
tonegate_queued_at=""
next_repository
assert_equal jai/trips-frontend "$selected_repository"
frontend_queued_at=""
if next_repository; then
  print -u2 -- 'Expected no queued repository'
  exit 1
fi
repository_oldest_queued_job_timestamp() { return 2; }
if next_repository; then
  print -u2 -- 'Expected queue lookup failures to propagate'
  exit 1
else
  assert_equal 2 "$?"
fi
functions[repository_oldest_queued_job_timestamp]="$production_repository_oldest_queued_job_timestamp"

assert_equal 20 "$minimum_root_free_gib"

cache_home="${test_directory}/runner-home"
cache_work="${test_directory}/runner-work"
mkdir -p "${cache_home}/.maestro/tests" "${cache_home}/Library/Logs/maestro"
touch "${cache_home}/.maestro/tests/stale.log"
touch "${cache_home}/Library/Logs/maestro/stale.log"
eval "$(runner_home_cache_setup_command "$cache_home" "$cache_work")"
[[ -L "${cache_home}/.maestro" ]]
[[ -L "${cache_home}/Library/Logs/maestro" ]]
assert_equal "${cache_work}/maestro" "$(readlink "${cache_home}/.maestro")"
assert_equal "${cache_work}/maestro-logs" "$(readlink "${cache_home}/Library/Logs/maestro")"
[[ -d "${cache_work}/maestro" ]]
[[ ! -e "${cache_work}/maestro/tests/stale.log" ]]

runner_environment_setup=$(runner_environment_setup_command "$cache_work")
runner_environment=$(env -i zsh -c "${runner_environment_setup}; print -r -- \"\$TMPDIR|\$TMP|\$TEMP|\$JAVA_TOOL_OPTIONS|\$XDG_CACHE_HOME|\$npm_config_cache\"")
assert_equal "${cache_work}/tmp|${cache_work}/tmp|${cache_work}/tmp|-Djava.io.tmpdir=${cache_work}/java-tmp|${cache_work}/user-cache|${cache_work}/npm-cache" "$runner_environment"

fake_guest_bin="${test_directory}/guest-bin"
mkdir -p "$fake_guest_bin"
cat > "${fake_guest_bin}/xcodebuild" <<'SCRIPT'
#!/bin/zsh
exit 0
SCRIPT
cat > "${fake_guest_bin}/java" <<'SCRIPT'
#!/bin/zsh
exit 17
SCRIPT
chmod 700 "${fake_guest_bin}/xcodebuild" "${fake_guest_bin}/java"
assert_equal '/opt/homebrew/bin/java -version >/dev/null 2>&1' "$(guest_preflight_java_command)"
if guest_preflight_output=$(PATH="${fake_guest_bin}:$PATH" zsh -c "$(guest_preflight_script_prefix); preflight_stage=xcode; xcodebuild -version >/dev/null; preflight_stage=java; ${fake_guest_bin}/java -version >/dev/null" 2>&1); then
  print -u2 -- 'Expected Java guest preflight stage to fail'
  exit 1
else
  guest_preflight_status=$?
fi
assert_equal 17 "$guest_preflight_status"
assert_equal 'guest-preflight failed stage=java status=17' "$guest_preflight_output"

runner_lookup 'jai/trips-frontend' 'page-two-runner'
assert_equal $'4343\tidle\tself-hosted,macos,arm64,tart,ios' "$REPLY"
runner_busy_state 'jai/trips-frontend' 'page-two-runner'
assert_equal idle "$REPLY"
runner_has_expected_labels 'self-hosted,macos,arm64,tart,ios'
runner_label_state 'self-hosted,macos,arm64,tart'
assert_equal pending "$REPLY"
runner_label_state 'self-hosted,macos,arm64,tart,ios,extra'
assert_equal unexpected "$REPLY"
if runner_has_expected_labels 'self-hosted,macos,arm64,borg-cube-03,tart,ios'; then
  print -u2 -- 'Expected a runner with a physical-host label to be rejected'
  exit 1
fi
if runner_has_expected_labels 'self-hosted,macos,arm64,tart,ios,extra'; then
  print -u2 -- 'Expected a runner with an unexpected label to be rejected'
  exit 1
fi

(
  sleep 3
) &
fake_runner_pid=$!
runner_busy_state() { REPLY=busy; }
wait_for_runner_claim 'jai/trips-frontend' 'test-runner' "$fake_runner_pid"
kill "$fake_runner_pid" 2>/dev/null || true
wait "$fake_runner_pid" 2>/dev/null || true

label_probe_count=0
(
  sleep 3
) &
fake_runner_pid=$!
runner_busy_state() {
  label_probe_count=$((label_probe_count + 1))
  if (( label_probe_count < 3 )); then
    REPLY=label-mismatch
    return 3
  fi
  REPLY=busy
}
wait_for_runner_claim 'jai/trips-frontend' 'test-runner' "$fake_runner_pid"
assert_equal 3 "$label_probe_count"
kill "$fake_runner_pid" 2>/dev/null || true
wait "$fake_runner_pid" 2>/dev/null || true

(
  sleep 3
) &
fake_runner_pid=$!
runner_busy_state() { REPLY=label-unexpected; return 4; }
if wait_for_runner_claim 'jai/trips-frontend' 'test-runner' "$fake_runner_pid"; then
  print -u2 -- 'Expected a runner with an unexpected label to fail closed'
  exit 1
else
  assert_equal 4 "$?"
fi
kill "$fake_runner_pid" 2>/dev/null || true
wait "$fake_runner_pid" 2>/dev/null || true

(
  sleep 3
) &
fake_runner_pid=$!
runner_busy_state() { REPLY=idle; }
if wait_for_runner_claim 'jai/trips-frontend' 'test-runner' "$fake_runner_pid"; then
  print -u2 -- 'Expected a confirmed idle runner to time out'
  exit 1
else
  assert_equal 2 "$?"
fi
kill "$fake_runner_pid" 2>/dev/null || true
wait "$fake_runner_pid" 2>/dev/null || true

(
  exit 23
) &
fake_runner_pid=$!
if wait_for_runner_claim 'jai/trips-frontend' 'test-runner' "$fake_runner_pid"; then
  print -u2 -- 'Expected an exited runner process to remain a failure'
  exit 1
else
  assert_equal 1 "$?"
fi
wait "$fake_runner_pid" 2>/dev/null || true

( exit 23 ) &
fake_runner_pid=$!
resolve_runner_status 1 "$fake_runner_pid" 'test-runner'
assert_equal 1 "$REPLY"

export FAKE_VM_PRESENT=true
if delete_vm 'test-vm'; then
  print -u2 -- 'Expected Tart deletion to fail closed while the VM remains present'
  exit 1
fi
if cleanup_runner_vm 'jai/trips-frontend' 'test-runner' 'test-vm' "${test_directory}/work.raw"; then
  print -u2 -- 'Expected Tart cleanup to propagate VM deletion failure'
  exit 1
fi
export FAKE_VM_PRESENT=false
delete_vm 'test-vm'
empty_inventory=$(list_ephemeral_vms) || {
  print -u2 -- 'Expected an empty Tart inventory to succeed with no stale VMs'
  exit 1
}
assert_equal '' "$empty_inventory"
export FAKE_STALE_VM_PRESENT=true
assert_equal 'trips-runner-job-stale' "$(list_ephemeral_vms)"
export FAKE_STALE_VM_PRESENT=false
export FAKE_VM_INVENTORY_ERROR=true
if delete_vm 'test-vm'; then
  print -u2 -- 'Expected Tart deletion to fail closed when inventory verification fails'
  exit 1
fi
if list_ephemeral_vms >/dev/null; then
  print -u2 -- 'Expected Tart startup inventory failure to propagate'
  exit 1
fi
export FAKE_VM_INVENTORY_ERROR=false

export FAKE_TART_RUN_LOG="${test_directory}/tart-run.log"
: > "$FAKE_TART_RUN_LOG"
export FAKE_EPHEMERAL_STATE=running
if reconcile_startup_ephemeral_vms; then
  print -u2 -- 'Expected a running startup VM to be preserved and block startup'
  exit 1
else
  assert_equal 1 "$?"
fi
if /usr/bin/grep -Eq '^(stop|delete) trips-runner-job-stale$' "$FAKE_TART_RUN_LOG"; then
  print -u2 -- 'Running startup VM was destructively reconciled'
  exit 1
fi
export FAKE_EPHEMERAL_STATE=stopped
reconcile_startup_ephemeral_vms
/usr/bin/grep -q '^delete trips-runner-job-stale$' "$FAKE_TART_RUN_LOG"
export FAKE_EPHEMERAL_STATE=''

export FAKE_RUNNING_VM=tonegate-search-20260825
if native_capacity_available; then
  print -u2 -- 'Expected an unrelated running Tart VM to hold native capacity'
  exit 1
else
  assert_equal 1 "$?"
  assert_equal tonegate-search-20260825 "$REPLY"
fi
export FAKE_RUNNING_VM=''
native_capacity_available
assert_equal '' "$REPLY"
export FAKE_VM_INVENTORY_ERROR=true
if native_capacity_available; then
  print -u2 -- 'Expected a Tart inventory failure to fail native capacity closed'
  exit 1
else
  assert_equal 2 "$?"
fi
export FAKE_VM_INVENTORY_ERROR=false

acquire_controller_lock
if TRIPS_RUNNER_CONTROLLER_LIBRARY_ONLY=true \
  TRIPS_TART_CONTROLLER_LOCK="$TRIPS_TART_CONTROLLER_LOCK" \
  zsh -uc 'source "$1"; acquire_controller_lock' \
  _ "${repo_root}/scripts/trips-tart-runner-controller.zsh"; then
  print -u2 -- 'Expected the controller singleton lock to reject a live contender'
  exit 1
fi
release_controller_lock

: > "$FAKE_TART_RUN_LOG"
export FAKE_VM_INVENTORY_ERROR=true
if acquire_clean_native_lane; then
  start_tart_vm inventory-error-vm "${test_directory}/inventory-error.raw" "${test_directory}/inventory-error.log"
  exit 1
else
  assert_equal 2 "$?"
fi
if /usr/bin/grep -q '^run ' "$FAKE_TART_RUN_LOG"; then
  print -u2 -- 'Inventory failure reached Tart run'
  exit 1
fi
export FAKE_VM_INVENTORY_ERROR=false

: > "$FAKE_TART_RUN_LOG"
lane_ready="${test_directory}/lane-ready"
lane_release="${test_directory}/lane-release"
TRIPS_RUNNER_CONTROLLER_LIBRARY_ONLY=true \
  TRIPS_TART_CLI="$fake_tart" \
  TRIPS_TART_NATIVE_LANE_LOCK="$TRIPS_TART_NATIVE_LANE_LOCK" \
  FAKE_TART_RUN_LOG="$FAKE_TART_RUN_LOG" \
  zsh -uc 'source "$1"; acquire_clean_native_lane || exit $?; start_tart_vm first-vm "$2" "$3" shared; first_pid="$REPLY"; wait "$first_pid"; : > "$4"; while [[ ! -e "$5" ]]; do sleep 0.02; done; release_native_lane' \
  _ "${repo_root}/scripts/trips-tart-runner-controller.zsh" "${test_directory}/first.raw" "${test_directory}/first.log" "$lane_ready" "$lane_release" &
first_contender_pid=$!
for _ in {1..50}; do
  [[ -e "$lane_ready" ]] && break
  sleep 0.02
done
[[ -e "$lane_ready" ]] || {
  print -u2 -- 'First native-lane contender did not acquire the lock'
  exit 1
}
TRIPS_RUNNER_CONTROLLER_LIBRARY_ONLY=true \
  TRIPS_TART_CLI="$fake_tart" \
  TRIPS_TART_NATIVE_LANE_LOCK="$TRIPS_TART_NATIVE_LANE_LOCK" \
  FAKE_TART_RUN_LOG="$FAKE_TART_RUN_LOG" \
  zsh -uc 'source "$1"; if acquire_clean_native_lane; then start_tart_vm second-vm "$2" "$3" shared; second_pid="$REPLY"; wait "$second_pid"; release_native_lane; fi' \
  _ "${repo_root}/scripts/trips-tart-runner-controller.zsh" "${test_directory}/second.raw" "${test_directory}/second.log"
: > "$lane_release"
wait "$first_contender_pid"
assert_equal 0 "$?"
assert_equal 1 "$(/usr/bin/grep -c '^run ' "$FAKE_TART_RUN_LOG")"

assert_configured_network_invocation() {
  local configured_mode="$1" vm_name="$2" expected_invocation="$3"
  local work_disk="${test_directory}/${vm_name}.raw" vm_log="${test_directory}/${vm_name}.log"
  : > "$FAKE_TART_RUN_LOG"
  if [[ "$configured_mode" == unset ]]; then
    env -u TRIPS_TART_NETWORK_MODE \
      TRIPS_RUNNER_CONTROLLER_LIBRARY_ONLY=true \
      TRIPS_TART_CLI="$fake_tart" \
      FAKE_TART_RUN_LOG="$FAKE_TART_RUN_LOG" \
      zsh -uc 'source "$1"; start_tart_vm "$2" "$3" "$4"; tart_pid="$REPLY"; wait "$tart_pid"' \
      _ "${repo_root}/scripts/trips-tart-runner-controller.zsh" "$vm_name" "$work_disk" "$vm_log"
  else
    TRIPS_TART_NETWORK_MODE="$configured_mode" \
      TRIPS_RUNNER_CONTROLLER_LIBRARY_ONLY=true \
      TRIPS_TART_CLI="$fake_tart" \
      FAKE_TART_RUN_LOG="$FAKE_TART_RUN_LOG" \
      zsh -uc 'source "$1"; start_tart_vm "$2" "$3" "$4"; tart_pid="$REPLY"; wait "$tart_pid"' \
      _ "${repo_root}/scripts/trips-tart-runner-controller.zsh" "$vm_name" "$work_disk" "$vm_log"
  fi
  assert_equal "$expected_invocation" "$(tail -n 1 "$FAKE_TART_RUN_LOG")"
}

assert_configured_network_invocation unset default-vm \
  'run --no-graphics --no-audio --no-clipboard --disk='"${test_directory}/default-vm.raw"' default-vm'
assert_configured_network_invocation shared shared-vm \
  'run --no-graphics --no-audio --no-clipboard --disk='"${test_directory}/shared-vm.raw"' shared-vm'
assert_configured_network_invocation softnet softnet-vm \
  'run --no-graphics --no-audio --no-clipboard --net-softnet --disk='"${test_directory}/softnet-vm.raw"' softnet-vm'

if start_tart_vm 'invalid-vm' "${test_directory}/invalid.raw" "${test_directory}/invalid.log" unsupported; then
  print -u2 -- 'Expected an unsupported Tart network mode to fail closed'
  exit 1
fi

export FAKE_SCENARIO=incompatible-host
if workflow_run_oldest_queued_job_timestamp jai/trips-frontend 303 | /usr/bin/grep -q .; then
  print -u2 -- 'Expected a job with a physical-host label to be rejected'
  exit 1
fi

print -r -- 'Tart controller repository selection passed.'
