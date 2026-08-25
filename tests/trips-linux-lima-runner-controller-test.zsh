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
exit 0
SCRIPT
chmod 700 "$fake_lima"

export TRIPS_LINUX_RUNNER_CONTROLLER_LIBRARY_ONLY=true
export TRIPS_LINUX_LIMA_SLOT=a
export TRIPS_LINUX_LIMA_GH_CLI="$fake_gh"
export TRIPS_LINUX_LIMA_CURL_CLI="$fake_curl"
export TRIPS_LINUX_LIMA_CLI="$fake_lima"
export TRIPS_LINUX_LIMA_REPOSITORIES='jai/tonegate,jai/trips-api,jai/trips-frontend'
export TRIPS_LINUX_LIMA_CLAIM_TIMEOUT_SECONDS=1
export TRIPS_LINUX_LIMA_CLAIM_POLL_SECONDS=0.1
export TRIPS_LINUX_LIMA_PACKAGE_MANAGER_TIMEOUT_SECONDS=10
export TRIPS_LINUX_LIMA_PACKAGE_MANAGER_POLL_SECONDS=4
export TRIPS_LINUX_LIMA_PACKAGE_MANAGER_PROBE_TIMEOUT_SECONDS=1
source "${repo_root}/scripts/trips-linux-lima-runner-controller.zsh"
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
assert_equal jai/trips-api "$selected_repository"
api_queued_at=""
next_repository
assert_equal jai/trips-frontend "$selected_repository"
tonegate_queued_at=""
frontend_queued_at=""
if next_repository; then
  print -u2 -- 'Expected no queued Linux repository'
  exit 1
fi

repository_oldest_queued_job_timestamp() { return 2; }
if next_repository; then
  print -u2 -- 'Expected queue API failures to propagate'
  exit 1
else
  assert_equal 2 "$?"
fi
functions[repository_oldest_queued_job_timestamp]="$production_repository_oldest_queued_job_timestamp"

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
