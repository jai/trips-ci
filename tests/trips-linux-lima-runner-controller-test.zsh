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
  print -r -- $'101\tjai/tonegate'
elif [[ "$request" == *'/actions/runs/101/jobs?'* ]]; then
  case "${FAKE_SCENARIO:-}" in
    standard) print -r -- '[{"jobs":[{"status":"queued","labels":["self-hosted","linux","ARM64","jai-ci"]}]}]' ;;
    tonegate) print -r -- '[{"jobs":[{"status":"queued","labels":["self-hosted","linux","ARM64","jai-ci-tonegate"]}]}]' ;;
    incompatible) print -r -- '[{"jobs":[{"status":"queued","labels":["self-hosted","linux","ARM64","another-host"]}]}]' ;;
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
export TRIPS_LINUX_LIMA_REPOSITORIES='jai/tonegate'
export TRIPS_LINUX_LIMA_CLAIM_TIMEOUT_SECONDS=1
export TRIPS_LINUX_LIMA_CLAIM_POLL_SECONDS=0.1
source "${repo_root}/scripts/trips-linux-lima-runner-controller.zsh"
installation_token_value=test-token
installation_token_expires_at=4102444800

assert_equal() {
  [[ "$1" == "$2" ]] || { print -u2 -- "Expected '$1', got '$2'"; return 1; }
}

for scenario in standard tonegate; do
  export FAKE_SCENARIO="$scenario"
  assert_equal 'jai/tonegate' "$(next_repository)"
done
export FAKE_SCENARIO=incompatible
if next_repository >/dev/null; then
  print -u2 -- 'Expected an incompatible Linux label to be rejected'
  exit 1
fi

if [[ ",${repositories}," == *',jai/trips-ci,'* ]]; then
  print -u2 -- 'Expected the public trips-ci repository to stay off private self-hosted runners'
  exit 1
fi

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
