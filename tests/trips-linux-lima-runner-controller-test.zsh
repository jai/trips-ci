#!/bin/zsh
set -eu

repo_root="${0:A:h:h}"
mkdir -p "${repo_root}/tmp"
test_directory=$(mktemp -d "${repo_root}/tmp/linux-controller-test.XXXXXX")
trap '/bin/rm -rf -- "$test_directory"' EXIT

fake_gh="${test_directory}/gh"
cat > "$fake_gh" <<'SCRIPT'
#!/bin/zsh
set -eu
request="$*"
[[ -n "${FAKE_GH_REQUEST_LOG:-}" ]] && print -r -- "$request" >> "$FAKE_GH_REQUEST_LOG"
if [[ "$request" == *'/actions/runs?'* ]]; then
  print -r -- $'101\t2026-08-25T00:00:00Z\tjai/tonegate'
elif [[ "$request" == *'/actions/runs/101/jobs?'* ]]; then
  case "${FAKE_SCENARIO:-}" in
    standard) print -r -- '[{"jobs":[{"status":"queued","created_at":"2026-08-25T00:00:01Z","labels":["self-hosted","linux","ARM64","jai-ci"]}]}]' ;;
    tonegate) print -r -- '[{"jobs":[{"status":"queued","created_at":"2026-08-25T00:00:02Z","labels":["self-hosted","linux","ARM64","jai-ci-tonegate"]}]}]' ;;
    incompatible) print -r -- '[{"jobs":[{"status":"queued","created_at":"2026-08-25T00:00:03Z","labels":["self-hosted","linux","ARM64","another-host"]}]}]' ;;
    *) print -r -- '[{"jobs":[]}]' ;;
  esac
fi
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
  print -r -- '{"runners":[{"id":4242,"name":"page-two-runner","busy":true}]}'
else
  print -u2 -- "Unexpected curl request: ${request}"
  exit 1
fi
SCRIPT
chmod 700 "$fake_curl"

fake_lima="${test_directory}/limactl"
cat > "$fake_lima" <<'SCRIPT'
#!/bin/zsh
set -eu
if [[ "$*" == *'test -x /usr/bin/fuser'* ]]; then
  [[ "${FAKE_PACKAGE_FUSER_EXISTS:-true}" == true ]] || exit 1
  [[ "${FAKE_PACKAGE_SUDO_PREFLIGHT_OK:-true}" == true ]] || exit 1
  [[ "$*" == *'systemctl stop apt-daily.timer apt-daily-upgrade.timer'* ]] || exit 1
  [[ "$*" == *'systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service'* ]] || exit 1
  [[ "$*" == *'systemctl mask --runtime apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service'* ]] || exit 1
  [[ "${FAKE_PACKAGE_QUIESCE_OK:-true}" == true ]] || exit 1
  print -r -- quiesced > "${FAKE_PACKAGE_QUIESCE_FILE:?}"
  exit 0
fi
if [[ "$*" == *'sudo -n bash -c '*'/usr/bin/fuser '* ]]; then
  if [[ "${FAKE_PACKAGE_LOCK_PROBE_HANG:-false}" == true ]]; then
    /bin/sleep 10
  fi
  if [[ -n "${FAKE_PACKAGE_PROBE_SUDO_STATUS:-}" ]]; then
    exit "$FAKE_PACKAGE_PROBE_SUDO_STATUS"
  fi
  if [[ -n "${FAKE_PACKAGE_LOCK_PROBE_STATUS:-}" ]]; then
    exit "$FAKE_PACKAGE_LOCK_PROBE_STATUS"
  fi
  attempts_file="${FAKE_PACKAGE_LOCK_ATTEMPTS_FILE:?}"
  attempts=$(cat "$attempts_file")
  attempts=$((attempts + 1))
  print -r -- "$attempts" > "$attempts_file"
  (( attempts > ${FAKE_PACKAGE_LOCK_BUSY_ATTEMPTS:-0} )) && exit 10 || exit 0
fi
if [[ "$1" == list && "${FAKE_VM_INVENTORY_ERROR:-false}" == true ]]; then
  exit 42
fi
if [[ "$1" == list && "${FAKE_VM_PRESENT:-false}" == true ]]; then
  print -r -- '{"name":"test-vm","status":"Stopped"}'
  exit 0
fi
if [[ "$1" == list ]]; then
  exit 0
fi
if [[ "$1" == clone && "${FAKE_CLONE_FAILURE:-false}" == true ]]; then
  exit 42
fi
exit 0
SCRIPT
chmod 700 "$fake_lima"

export TRIPS_LINUX_RUNNER_CONTROLLER_LIBRARY_ONLY=true
export TRIPS_LINUX_LIMA_SLOT=a
export LIMA_HOME="${test_directory}/lima-home"
export TRIPS_LINUX_LIMA_GH_CLI="$fake_gh"
export TRIPS_LINUX_LIMA_CURL_CLI="$fake_curl"
export TRIPS_LINUX_LIMA_CLI="$fake_lima"
export TRIPS_LINUX_LIMA_REPOSITORIES='jai/tonegate,jai/trips-api,jai/trips-frontend'
export TRIPS_LINUX_LIMA_CLAIM_TIMEOUT_SECONDS=1
export TRIPS_LINUX_LIMA_CLAIM_POLL_SECONDS=0.1
export TRIPS_LINUX_LIMA_PACKAGE_MANAGER_TIMEOUT_SECONDS=10
export TRIPS_LINUX_LIMA_PACKAGE_MANAGER_POLL_SECONDS=4
export TRIPS_LINUX_LIMA_PACKAGE_MANAGER_PROBE_TIMEOUT_SECONDS=1
export TRIPS_LINUX_LIMA_SELECTION_LOCK_OWNER_GRACE_SECONDS=1
source "${repo_root}/scripts/trips-linux-lima-runner-controller.zsh"
mkdir -p "$LIMA_HOME"
installation_token_value=test-token
installation_token_expires_at=4102444800

assert_equal() {
  [[ "$1" == "$2" ]] || { print -u2 -- "Expected '$1', got '$2'"; return 1; }
}

if [[ -o pipefail ]]; then
  print -u2 -- 'Controller source must not enable pipefail globally'
  exit 1
fi
printf '%s' probe | base64url >/dev/null
if [[ -o pipefail ]]; then
  print -u2 -- 'Pipeline helpers must restore the caller pipefail setting'
  exit 1
fi

export FAKE_SCENARIO=standard
assert_equal 2026-08-25T00:00:01Z "$(workflow_run_oldest_queued_job_timestamp jai/tonegate 101)"
export FAKE_SCENARIO=tonegate
assert_equal 2026-08-25T00:00:02Z "$(workflow_run_oldest_queued_job_timestamp jai/tonegate 101)"
export FAKE_SCENARIO=incompatible
if workflow_run_oldest_queued_job_timestamp jai/tonegate 101 | /usr/bin/grep -q .; then
  print -u2 -- 'Expected an incompatible Linux label to be rejected'
  exit 1
fi

export FAKE_GH_REQUEST_LOG="${test_directory}/gh-requests.log"
export FAKE_SCENARIO=standard
: > "$FAKE_GH_REQUEST_LOG"
assert_equal 2026-08-25T00:00:01Z "$(repository_oldest_queued_job_timestamp jai/tonegate)"
assert_equal 1 "$(/usr/bin/grep -c '/actions/runs?' "$FAKE_GH_REQUEST_LOG")"
if /usr/bin/grep -q 'status=in_progress' "$FAKE_GH_REQUEST_LOG"; then
  print -u2 -- 'Expected queue discovery to stop before scanning in-progress runs'
  exit 1
fi
unset FAKE_GH_REQUEST_LOG

if [[ ",${repositories}," == *',jai/trips-ci,'* ]]; then
  print -u2 -- 'Expected the public trips-ci repository to stay off private self-hosted runners'
  exit 1
fi

typeset production_repository_oldest_queued_job_timestamp="${functions[repository_oldest_queued_job_timestamp]}"
typeset -g tonegate_queued_at=2026-08-25T00:03:00Z
typeset -g api_queued_at=2026-08-25T00:01:00Z
typeset -g frontend_queued_at=2026-08-25T00:02:00Z
repository_oldest_queued_job_timestamp() {
  local queued_at
  case "$1" in
    jai/tonegate) queued_at="$tonegate_queued_at" ;;
    jai/trips-api) queued_at="$api_queued_at" ;;
    jai/trips-frontend) queued_at="$frontend_queued_at" ;;
    *) return 1 ;;
  esac
  [[ -n "$queued_at" ]] || return 1
  print -r -- "$queued_at"
}
next_repository
assert_equal jai/tonegate "$selected_repository"
release_selection_lock
repository_scan_start_index=2
next_repository
assert_equal jai/trips-api "$selected_repository"
release_selection_lock
repository_scan_start_index=1
tonegate_queued_at=""
next_repository
assert_equal jai/trips-api "$selected_repository"
release_selection_lock
api_queued_at=""
next_repository
assert_equal jai/trips-frontend "$selected_repository"
release_selection_lock
frontend_queued_at=""
if next_repository; then
  print -u2 -- 'Expected no queued Linux repository'
  exit 1
fi

tonegate_queued_at=2026-08-25T00:03:00Z
api_queued_at=2026-08-25T00:01:00Z
frontend_queued_at=2026-08-25T00:02:00Z
repository_scan_start_index=1
selection_lock_path jai/tonegate
reserved_tonegate_lock="$REPLY"
mkdir "$reserved_tonegate_lock"
print -r -- $$ > "${reserved_tonegate_lock}/pid"
next_repository
assert_equal jai/trips-api "$selected_repository"
release_selection_lock
rm -rf "$reserved_tonegate_lock"

selection_lock_path jai/tonegate
stale_tonegate_lock="$REPLY"
mkdir "$stale_tonegate_lock"
print -r -- 999999 > "${stale_tonegate_lock}/pid"
repository_scan_start_index=1
next_repository
assert_equal jai/tonegate "$selected_repository"
assert_equal "$stale_tonegate_lock" "$selected_repository_lock"
release_selection_lock

selection_lock_path jai/tonegate
ownerless_tonegate_lock="$REPLY"
mkdir "$ownerless_tonegate_lock"
/usr/bin/touch -t 200001010000 "$ownerless_tonegate_lock"
acquire_selection_lock jai/tonegate
assert_equal "$ownerless_tonegate_lock" "$selected_repository_lock"
release_selection_lock

stale_contention_home="${test_directory}/stale-contention-locks"
stale_contention_lock="${stale_contention_home}/.trips-linux-runner-selection-lock-jai-tonegate"
stale_contention_start="${test_directory}/stale-contention-start"
stale_contention_ready="${test_directory}/stale-contention-ready"
stale_contention_winners="${test_directory}/stale-contention-winners"
mkdir -p "$stale_contention_lock" "$stale_contention_ready"
print -r -- 999999 > "${stale_contention_lock}/pid"
: > "$stale_contention_winners"
for contender in {1..12}; do
  env \
    TRIPS_LINUX_RUNNER_CONTROLLER_LIBRARY_ONLY=true \
    TRIPS_LINUX_LIMA_SLOT=a \
    LIMA_HOME="$stale_contention_home" \
    /bin/zsh -c '
      source "$1"
      : > "$2/$3"
      while [[ ! -e "$4" ]]; do /bin/sleep 0.001; done
      if acquire_selection_lock jai/tonegate; then
        print -r -- "$$" >> "$5"
        /bin/sleep 0.2
        release_selection_lock
      fi
    ' zsh "${repo_root}/scripts/trips-linux-lima-runner-controller.zsh" \
      "$stale_contention_ready" "$contender" "$stale_contention_start" \
      "$stale_contention_winners" &
done
while (( $(find "$stale_contention_ready" -type f | wc -l | tr -d ' ') < 12 )); do
  /bin/sleep 0.002
done
: > "$stale_contention_start"
wait
assert_equal 1 "$(wc -l < "$stale_contention_winners" | tr -d ' ')"
if find "$stale_contention_home" -maxdepth 1 -name '*.reclaim' | /usr/bin/grep -q .; then
  print -u2 -- 'Expected stale-lock recovery guards to be cleaned up'
  exit 1
fi

acquire_selection_lock jai/tonegate
typeset production_repository_is_private="${functions[repository_is_private]}"
typeset production_cleanup_runner_vm="${functions[cleanup_runner_vm]}"
typeset -ga clone_failure_cleanup=()
repository_is_private() { return 0; }
cleanup_runner_vm() { clone_failure_cleanup=("$1" "$2" "$3"); }
export FAKE_CLONE_FAILURE=true
if run_one_ephemeral_runner jai/tonegate; then
  print -u2 -- 'Expected a clone failure to fail the runner cycle'
  exit 1
fi
unset FAKE_CLONE_FAILURE
functions[repository_is_private]="$production_repository_is_private"
functions[cleanup_runner_vm]="$production_cleanup_runner_vm"
if [[ -n "$selected_repository_lock" || -d "$ownerless_tonegate_lock" ]]; then
  print -u2 -- 'Expected a clone failure to release its repository reservation'
  exit 1
fi
assert_equal jai/tonegate "${clone_failure_cleanup[1]}"
[[ "${clone_failure_cleanup[2]}" == borg-cube-03-lima-a-* ]] || {
  print -u2 -- 'Expected clone failure cleanup to receive the runner name'
  exit 1
}
[[ "${clone_failure_cleanup[3]}" == trips-linux-runner-a-job-* ]] || {
  print -u2 -- 'Expected clone failure cleanup to receive the partially created VM name'
  exit 1
}

clone_signal_home="${test_directory}/clone-signal-home"
clone_signal_started="${test_directory}/clone-signal-started"
clone_signal_cleanup="${test_directory}/clone-signal-cleanup"
clone_signal_runner="${test_directory}/clone-signal-runner"
clone_signal_lima="${test_directory}/clone-signal-lima"
cat > "$clone_signal_lima" <<'SCRIPT'
#!/bin/zsh
set -eu
if [[ "$1" == clone ]]; then
  print -r -- started > "${FAKE_CLONE_SIGNAL_STARTED:?}"
  /bin/sleep 5
fi
SCRIPT
chmod 700 "$clone_signal_lima"
cat > "$clone_signal_runner" <<SCRIPT
#!/bin/zsh
set -u
export TRIPS_LINUX_RUNNER_CONTROLLER_LIBRARY_ONLY=true
export TRIPS_LINUX_LIMA_SLOT=a
export LIMA_HOME='${clone_signal_home}'
export TRIPS_LINUX_LIMA_CLI='${clone_signal_lima}'
export FAKE_CLONE_SIGNAL_STARTED='${clone_signal_started}'
source '${repo_root}/scripts/trips-linux-lima-runner-controller.zsh'
mkdir -p "\$LIMA_HOME"
repository_is_private() { return 0; }
cleanup_runner_vm() { print -r -- cleaned > '${clone_signal_cleanup}'; }
acquire_selection_lock jai/tonegate
run_one_ephemeral_runner jai/tonegate
SCRIPT
chmod 700 "$clone_signal_runner"
"$clone_signal_runner" &
clone_signal_pid=$!
for _ in {1..200}; do
  [[ -e "$clone_signal_started" ]] && break
  /bin/sleep 0.01
done
if [[ ! -e "$clone_signal_started" ]]; then
  print -u2 -- 'Expected the clone signal test to enter Lima clone'
  exit 1
fi
clone_signal_started_at=$(/bin/date +%s)
/bin/kill -TERM "$clone_signal_pid"
clone_signal_status=0
wait "$clone_signal_pid" 2>/dev/null || clone_signal_status=$?
clone_signal_elapsed=$(( $(/bin/date +%s) - clone_signal_started_at ))
assert_equal 130 "$clone_signal_status"
if (( clone_signal_elapsed > 2 )); then
  print -u2 -- "Expected SIGTERM during external clone to finish promptly; took ${clone_signal_elapsed}s"
  exit 1
fi
if [[ ! -e "$clone_signal_cleanup" ]]; then
  print -u2 -- 'Expected SIGTERM during clone to clean the partial VM'
  exit 1
fi
selection_lock_path jai/tonegate
if [[ -d "${clone_signal_home}/${REPLY:t}" ]]; then
  print -u2 -- 'Expected SIGTERM during clone to release the repository reservation'
  exit 1
fi

concurrent_lock_home="${test_directory}/concurrent-locks"
concurrent_selection_output="${test_directory}/concurrent-selections"
mkdir "$concurrent_lock_home"
for concurrent_slot in a b; do
  env \
    TRIPS_LINUX_RUNNER_CONTROLLER_LIBRARY_ONLY=true \
    TRIPS_LINUX_LIMA_SLOT="$concurrent_slot" \
    LIMA_HOME="$concurrent_lock_home" \
    TRIPS_LINUX_LIMA_REPOSITORIES='jai/tonegate,jai/trips-api,jai/trips-frontend' \
    /bin/zsh -c '
      source "$1"
      repository_oldest_queued_job_timestamp() { print -r -- 2026-08-25T00:00:00Z; }
      next_repository
      print -r -- "slot=${slot} selected=${selected_repository}" >> "$2"
      /bin/sleep 0.2
      release_selection_lock
    ' zsh "${repo_root}/scripts/trips-linux-lima-runner-controller.zsh" "$concurrent_selection_output" &
done
wait
assert_equal $'slot=a selected=jai/tonegate\nslot=b selected=jai/trips-api' \
  "$(LC_ALL=C /usr/bin/sort "$concurrent_selection_output")"

repository_oldest_queued_job_timestamp() { return 2; }
if next_repository; then
  print -u2 -- 'Expected queue API failures to propagate'
  exit 1
else
  assert_equal 2 "$?"
fi
functions[repository_oldest_queued_job_timestamp]="$production_repository_oldest_queued_job_timestamp"

typeset production_selection_sleep="${functions[selection_sleep]}"
typeset -ga observed_selection_lock_states=()
typeset -ga observed_selection_sleep_durations=()
selection_sleep() {
  observed_selection_sleep_durations+=("$1")
  if [[ -n "$selected_repository_lock" && -d "$selected_repository_lock" ]]; then
    observed_selection_lock_states+=(locked)
  else
    observed_selection_lock_states+=(unlocked)
  fi
}

observed_selection_lock_states=()
observed_selection_sleep_durations=()
handle_no_selected_repository 1
assert_equal unlocked "${observed_selection_lock_states[1]}"
assert_equal 120 "${observed_selection_sleep_durations[1]}"

observed_selection_lock_states=()
observed_selection_sleep_durations=()
handle_no_selected_repository 2
assert_equal unlocked "${observed_selection_lock_states[1]}"
assert_equal 60 "${observed_selection_sleep_durations[1]}"
functions[selection_sleep]="$production_selection_sleep"

runner_lookup 'jai/tonegate' 'page-two-runner'
assert_equal $'4242\tbusy' "$REPLY"

( sleep 3 ) &
fake_runner_pid=$!
runner_busy_state() { REPLY=busy; }
wait_for_runner_claim 'jai/tonegate' 'test-runner' "$fake_runner_pid"
kill "$fake_runner_pid" 2>/dev/null || true
wait "$fake_runner_pid" 2>/dev/null || true

( sleep 3 ) &
fake_runner_pid=$!
runner_busy_state() { REPLY=idle; }
if wait_for_runner_claim 'jai/tonegate' 'test-runner' "$fake_runner_pid"; then
  print -u2 -- 'Expected a confirmed idle runner to time out'
  exit 1
else
  assert_equal 2 "$?"
fi
kill "$fake_runner_pid" 2>/dev/null || true
wait "$fake_runner_pid" 2>/dev/null || true

( exit 23 ) &
fake_runner_pid=$!
if wait_for_runner_claim 'jai/tonegate' 'test-runner' "$fake_runner_pid"; then
  print -u2 -- 'Expected an exited runner process to remain a failure'
  exit 1
else
  assert_equal 1 "$?"
fi
wait "$fake_runner_pid" 2>/dev/null || true

( exit 23 ) &
fake_runner_pid=$!
resolve_runner_status 1 "$fake_runner_pid" 'test-runner'
assert_equal 23 "$REPLY"

export FAKE_PACKAGE_LOCK_ATTEMPTS_FILE="${test_directory}/package-lock-attempts"
export FAKE_PACKAGE_QUIESCE_FILE="${test_directory}/package-manager-quiesced"
typeset production_package_manager_now="${functions[package_manager_now]}"
typeset production_package_manager_sleep="${functions[package_manager_sleep]}"
typeset -g fake_package_manager_now=100
typeset -ga fake_package_manager_sleeps=()
package_manager_now() {
  REPLY="$fake_package_manager_now"
}
package_manager_sleep() {
  fake_package_manager_sleeps+=("$1")
  fake_package_manager_now=$((fake_package_manager_now + $1))
}

print -r -- 0 > "$FAKE_PACKAGE_LOCK_ATTEMPTS_FILE"
export FAKE_PACKAGE_LOCK_BUSY_ATTEMPTS=2
fake_package_manager_now=100
fake_package_manager_sleeps=()
wait_for_guest_package_manager 'test-vm'
assert_equal 3 "$(cat "$FAKE_PACKAGE_LOCK_ATTEMPTS_FILE")"
assert_equal quiesced "$(cat "$FAKE_PACKAGE_QUIESCE_FILE")"

timeout_command="${test_directory}/timeout-command"
cat > "$timeout_command" <<'SCRIPT'
#!/bin/zsh
set -eu
print -r -- $$ > "${FAKE_TIMEOUT_COMMAND_PID_FILE:?}"
/bin/sleep 30 &
print -r -- $! > "${FAKE_TIMEOUT_CHILD_PID_FILE:?}"
wait
SCRIPT
chmod 700 "$timeout_command"
timeout_lifecycle="${test_directory}/timeout-lifecycle"
cat > "$timeout_lifecycle" <<SCRIPT
#!/bin/zsh
set -u
export TRIPS_LINUX_RUNNER_CONTROLLER_LIBRARY_ONLY=true
export TRIPS_LINUX_LIMA_SLOT=a
source '${repo_root}/scripts/trips-linux-lima-runner-controller.zsh'
trap 'stop_active_timeout; exit 130' INT TERM
(
  while [[ ! -s "\${FAKE_TIMEOUT_COMMAND_PID_FILE}" || ! -s "\${FAKE_TIMEOUT_CHILD_PID_FILE}" ]]; do /bin/sleep 0.05; done
  /bin/kill -TERM \$\$
) &
run_with_timeout 30 '${timeout_command}'
SCRIPT
chmod 700 "$timeout_lifecycle"
export FAKE_TIMEOUT_COMMAND_PID_FILE="${test_directory}/timeout-command.pid"
export FAKE_TIMEOUT_CHILD_PID_FILE="${test_directory}/timeout-child.pid"
if "$timeout_lifecycle"; then
  print -u2 -- 'Expected controller termination to interrupt the active timeout'
  exit 1
else
  assert_equal 130 "$?"
fi
timeout_command_pid=$(cat "$FAKE_TIMEOUT_COMMAND_PID_FILE")
timeout_child_pid=$(cat "$FAKE_TIMEOUT_CHILD_PID_FILE")
if /bin/kill -0 "$timeout_command_pid" 2>/dev/null || /bin/kill -0 "$timeout_child_pid" 2>/dev/null; then
  print -u2 -- 'Expected controller termination to reap the timeout process group'
  exit 1
fi

timeout_parent_death="${test_directory}/timeout-parent-death"
cat > "$timeout_parent_death" <<SCRIPT
#!/bin/zsh
set -u
export TRIPS_LINUX_RUNNER_CONTROLLER_LIBRARY_ONLY=true
export TRIPS_LINUX_LIMA_SLOT=a
source '${repo_root}/scripts/trips-linux-lima-runner-controller.zsh'
run_with_timeout 30 '${timeout_command}'
SCRIPT
chmod 700 "$timeout_parent_death"
rm -f "$FAKE_TIMEOUT_COMMAND_PID_FILE" "$FAKE_TIMEOUT_CHILD_PID_FILE"
"$timeout_parent_death" &
timeout_parent_pid=$!
for _ in {1..100}; do
  timeout_python_pid=$(/usr/bin/pgrep -P "$timeout_parent_pid" 2>/dev/null | /usr/bin/head -n 1 || true)
  [[ -n "$timeout_python_pid" && -s "$FAKE_TIMEOUT_COMMAND_PID_FILE" && -s "$FAKE_TIMEOUT_CHILD_PID_FILE" ]] && break
  /bin/sleep 0.02
done
if [[ -z "${timeout_python_pid:-}" ]]; then
  print -u2 -- 'Expected timeout helper to start before parent-death test'
  exit 1
fi
timeout_command_pid=$(cat "$FAKE_TIMEOUT_COMMAND_PID_FILE")
timeout_child_pid=$(cat "$FAKE_TIMEOUT_CHILD_PID_FILE")
/bin/kill -KILL "$timeout_parent_pid"
wait "$timeout_parent_pid" 2>/dev/null || true
for _ in {1..100}; do
  if ! /bin/kill -0 "$timeout_python_pid" 2>/dev/null &&
    ! /bin/kill -0 "$timeout_command_pid" 2>/dev/null &&
    ! /bin/kill -0 "$timeout_child_pid" 2>/dev/null; then
    break
  fi
  /bin/sleep 0.02
done
if /bin/kill -0 "$timeout_python_pid" 2>/dev/null ||
  /bin/kill -0 "$timeout_command_pid" 2>/dev/null ||
  /bin/kill -0 "$timeout_child_pid" 2>/dev/null; then
  print -u2 -- 'Expected parent-death guard to reap the timeout process group'
  exit 1
fi

blocked_signals=$(run_with_timeout 2 /usr/bin/python3 -c \
  'import signal; print(" ".join(sorted(item.name for item in signal.pthread_sigmask(signal.SIG_BLOCK, []))))')
assert_equal '' "$blocked_signals"
for signal_spec in HUP:129 INT:130 QUIT:131 TERM:143; do
  signal_name="${signal_spec%%:*}"
  expected_status="${signal_spec#*:}"
  if run_with_timeout 2 /usr/bin/python3 -c \
    'import os, signal, sys; os.kill(os.getpid(), getattr(signal, "SIG" + sys.argv[1])); raise SystemExit(99)' \
    "$signal_name" >/dev/null 2>&1; then
    print -u2 -- "Expected ${signal_name} to terminate the wrapped command"
    exit 1
  else
    assert_equal "$expected_status" "$?"
  fi
done

timeout_prelaunch_started="${test_directory}/timeout-prelaunch-started"
timeout_prelaunch_release="${test_directory}/timeout-prelaunch-release"
timeout_prelaunch_target_started="${test_directory}/timeout-prelaunch-target-started"
timeout_prelaunch_target="${test_directory}/timeout-prelaunch-target"
cat > "$timeout_prelaunch_target" <<'SCRIPT'
#!/bin/zsh
set -eu
print -r -- started > "${FAKE_TIMEOUT_PRELAUNCH_TARGET_STARTED:?}"
SCRIPT
chmod 700 "$timeout_prelaunch_target"
timeout_prelaunch_parent="${test_directory}/timeout-prelaunch-parent"
cat > "$timeout_prelaunch_parent" <<SCRIPT
#!/bin/zsh
set -u
export TRIPS_LINUX_RUNNER_CONTROLLER_LIBRARY_ONLY=true
export TRIPS_LINUX_LIMA_SLOT=a
export TRIPS_LINUX_LIMA_TIMEOUT_PREEXEC_READY_FILE='${timeout_prelaunch_started}'
export TRIPS_LINUX_LIMA_TIMEOUT_PREEXEC_RELEASE_FILE='${timeout_prelaunch_release}'
source '${repo_root}/scripts/trips-linux-lima-runner-controller.zsh'
run_with_timeout 30 '${timeout_prelaunch_target}'
SCRIPT
chmod 700 "$timeout_prelaunch_parent"
export FAKE_TIMEOUT_PRELAUNCH_TARGET_STARTED="$timeout_prelaunch_target_started"
"$timeout_prelaunch_parent" &
timeout_prelaunch_parent_pid=$!
for _ in {1..100}; do
  [[ -s "$timeout_prelaunch_started" ]] && break
  /bin/sleep 0.02
done
if [[ ! -s "$timeout_prelaunch_started" ]]; then
  print -u2 -- 'Expected delayed timeout helper to reach its pre-launch handshake'
  exit 1
fi
timeout_prelaunch_python_pid=$(/usr/bin/pgrep -P "$timeout_prelaunch_parent_pid" | /usr/bin/head -n 1)
if [[ -z "$timeout_prelaunch_python_pid" ]]; then
  print -u2 -- 'Expected timeout helper to remain alive during the child pre-exec window'
  exit 1
fi
timeout_prelaunch_child_pid=$(/usr/bin/pgrep -P "$timeout_prelaunch_python_pid" | /usr/bin/head -n 1)
if [[ -z "$timeout_prelaunch_child_pid" ]]; then
  print -u2 -- 'Expected wrapped child to wait at the pre-exec release barrier'
  exit 1
fi
/bin/kill -STOP "$timeout_prelaunch_python_pid"
for _ in {1..100}; do
  timeout_prelaunch_python_state=$(/bin/ps -o state= -p "$timeout_prelaunch_python_pid" | /usr/bin/tr -d ' ')
  [[ "$timeout_prelaunch_python_state" == T* ]] && break
  /bin/sleep 0.02
done
if [[ "${timeout_prelaunch_python_state:-}" != T* ]]; then
  /bin/kill -CONT "$timeout_prelaunch_python_pid" 2>/dev/null || true
  print -u2 -- 'Expected timeout helper to stop before the pre-launch parent-death assertion'
  exit 1
fi
/bin/kill -KILL "$timeout_prelaunch_parent_pid"
print -r -- released > "$timeout_prelaunch_release"
for _ in {1..100}; do
  timeout_prelaunch_child_state=$(/bin/ps -o state= -p "$timeout_prelaunch_child_pid" 2>/dev/null | /usr/bin/tr -d ' ' || true)
  [[ -z "$timeout_prelaunch_child_state" || "$timeout_prelaunch_child_state" == Z* ]] && break
  /bin/sleep 0.02
done
if [[ -n "${timeout_prelaunch_child_state:-}" && "$timeout_prelaunch_child_state" != Z* ]]; then
  /bin/kill -CONT "$timeout_prelaunch_python_pid" 2>/dev/null || true
  print -u2 -- 'Expected wrapped child to finish after crossing the pre-exec release barrier'
  exit 1
fi
timeout_prelaunch_target_was_started=false
[[ -e "$timeout_prelaunch_target_started" ]] && timeout_prelaunch_target_was_started=true
/bin/kill -CONT "$timeout_prelaunch_python_pid"
if [[ "$timeout_prelaunch_target_was_started" == true ]]; then
  print -u2 -- 'Expected the timeout target to remain unlaunched while its stopped helper cannot reap it'
  exit 1
fi
for _ in {1..100}; do
  ! /bin/kill -0 "$timeout_prelaunch_python_pid" 2>/dev/null && break
  /bin/sleep 0.02
done
if /bin/kill -0 "$timeout_prelaunch_python_pid" 2>/dev/null; then
  print -u2 -- 'Expected delayed timeout helper to exit after its parent died'
  exit 1
fi
wait "$timeout_prelaunch_parent_pid" 2>/dev/null || true

fake_provision_bin="${test_directory}/provision-bin"
mkdir -p "$fake_provision_bin"
fake_provision_log="${test_directory}/provision-order.log"
cat > "${fake_provision_bin}/systemctl" <<'SCRIPT'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "${FAKE_PROVISION_LOG:?}"
SCRIPT
cat > "${fake_provision_bin}/apt-get" <<'SCRIPT'
#!/bin/sh
printf 'apt-get %s\n' "$*" >> "${FAKE_PROVISION_LOG:?}"
exit 99
SCRIPT
chmod 700 "${fake_provision_bin}/systemctl" "${fake_provision_bin}/apt-get"
export FAKE_PROVISION_LOG="$fake_provision_log"
if PATH="${fake_provision_bin}:/usr/bin:/bin" /bin/bash "${repo_root}/scripts/provision-lima-runner-base.sh"; then
  print -u2 -- 'Expected the provision-order harness to stop at apt-get'
  exit 1
else
  assert_equal 99 "$?"
fi
assert_equal $'systemctl disable --now apt-daily.timer apt-daily-upgrade.timer\nsystemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service\nsystemctl mask apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service\napt-get update' "$(cat "$fake_provision_log")"

print -r -- 0 > "$FAKE_PACKAGE_LOCK_ATTEMPTS_FILE"
export FAKE_PACKAGE_LOCK_BUSY_ATTEMPTS=10000
fake_package_manager_now=100
fake_package_manager_sleeps=()
if wait_for_guest_package_manager 'test-vm'; then
  print -u2 -- 'Expected package-manager readiness to time out'
  exit 1
fi

export FAKE_PACKAGE_LOCK_PROBE_STATUS=42
fake_package_manager_now=100
if wait_for_guest_package_manager 'test-vm'; then
  print -u2 -- 'Expected a package-manager probe failure to fail closed'
  exit 1
fi
unset FAKE_PACKAGE_LOCK_PROBE_STATUS

export FAKE_PACKAGE_FUSER_EXISTS=false
fake_package_manager_now=100
if wait_for_guest_package_manager 'test-vm'; then
  print -u2 -- 'Expected a missing fuser to fail closed'
  exit 1
fi
unset FAKE_PACKAGE_FUSER_EXISTS

export FAKE_PACKAGE_SUDO_PREFLIGHT_OK=false
fake_package_manager_now=100
if wait_for_guest_package_manager 'test-vm'; then
  print -u2 -- 'Expected a sudo preflight failure to fail closed'
  exit 1
fi
unset FAKE_PACKAGE_SUDO_PREFLIGHT_OK

export FAKE_PACKAGE_QUIESCE_OK=false
fake_package_manager_now=100
if wait_for_guest_package_manager 'test-vm'; then
  print -u2 -- 'Expected an apt-service quiesce failure to fail closed'
  exit 1
fi
unset FAKE_PACKAGE_QUIESCE_OK

export FAKE_PACKAGE_PROBE_SUDO_STATUS=1
fake_package_manager_now=100
if wait_for_guest_package_manager 'test-vm'; then
  print -u2 -- 'Expected a probe-time sudo failure to fail closed'
  exit 1
fi
unset FAKE_PACKAGE_PROBE_SUDO_STATUS

export FAKE_PACKAGE_LOCK_PROBE_HANG=true
fake_package_manager_now=100
if wait_for_guest_package_manager 'test-vm'; then
  print -u2 -- 'Expected a hung package-manager probe to fail closed'
  exit 1
fi
unset FAKE_PACKAGE_LOCK_PROBE_HANG

print -r -- 0 > "$FAKE_PACKAGE_LOCK_ATTEMPTS_FILE"
export FAKE_PACKAGE_LOCK_BUSY_ATTEMPTS=10000
fake_package_manager_now=100
fake_package_manager_sleeps=()
if wait_for_guest_package_manager 'test-vm'; then
  print -u2 -- 'Expected the total package-manager deadline to fail closed'
  exit 1
fi
assert_equal 3 "$(cat "$FAKE_PACKAGE_LOCK_ATTEMPTS_FILE")"
assert_equal '4 4 2' "${fake_package_manager_sleeps[*]}"
functions[package_manager_now]="$production_package_manager_now"
functions[package_manager_sleep]="$production_package_manager_sleep"

export FAKE_VM_PRESENT=true
if delete_vm 'test-vm'; then
  print -u2 -- 'Expected Lima deletion to fail closed while the VM remains present'
  exit 1
fi
if cleanup_runner_vm 'jai/tonegate' 'test-runner' 'test-vm'; then
  print -u2 -- 'Expected Lima cleanup to propagate VM deletion failure'
  exit 1
fi
export FAKE_VM_PRESENT=false
delete_vm 'test-vm'
export FAKE_VM_INVENTORY_ERROR=true
if delete_vm 'test-vm'; then
  print -u2 -- 'Expected Lima deletion to fail closed when inventory verification fails'
  exit 1
fi
if list_ephemeral_vms >/dev/null; then
  print -u2 -- 'Expected Lima startup inventory failure to propagate'
  exit 1
fi

print -r -- 'Linux Lima controller selection and claim lifecycle passed.'
