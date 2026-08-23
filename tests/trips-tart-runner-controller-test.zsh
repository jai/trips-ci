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
      print -r -- $'101\tjai/tonegate'
    elif [[ "$request" == *'repos/jai/tonegate/actions/runs/101/jobs?'* ]]; then
      print -r -- '[{"jobs":[{"status":"queued","labels":["self-hosted","macOS","ARM64","tart","ios"]}]}]'
    fi
    ;;
  trips-first)
    if [[ "$request" == *'repos/jai/trips-frontend/actions/runs?'* ]]; then
      print -r -- $'202\tjai/trips-frontend'
    elif [[ "$request" == *'repos/jai/trips-frontend/actions/runs/202/jobs?'* ]]; then
      print -r -- '[{"jobs":[{"status":"queued","labels":["self-hosted","macOS","ARM64","tart","ios","borg-cube-03"]}]}]'
    fi
    ;;
  incompatible-host)
    if [[ "$request" == *'repos/jai/trips-frontend/actions/runs?'* ]]; then
      print -r -- $'303\tjai/trips-frontend'
    elif [[ "$request" == *'repos/jai/trips-frontend/actions/runs/303/jobs?'* ]]; then
      print -r -- '[{"jobs":[{"status":"queued","labels":["self-hosted","macOS","ARM64","tart","ios","another-host"]}]}]'
    fi
    ;;
  no-jobs)
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
  print -r -- '{"runners":[{"id":4343,"name":"page-two-runner","busy":false}]}'
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
if [[ "$1" == list && "${FAKE_VM_INVENTORY_ERROR:-false}" == true ]]; then
  exit 42
fi
if [[ "$1" == list && "${FAKE_VM_PRESENT:-false}" == true ]]; then
  print -r -- 'test-vm'
fi
exit 0
SCRIPT
chmod 700 "$fake_tart"

export TRIPS_RUNNER_CONTROLLER_LIBRARY_ONLY=true
export TRIPS_TART_GH_CLI="$fake_gh"
export TRIPS_TART_CURL_CLI="$fake_curl"
export TRIPS_TART_CLI="$fake_tart"
export TRIPS_TART_REPOSITORIES='jai/trips-frontend,jai/tonegate'
export TRIPS_TART_CLAIM_TIMEOUT_SECONDS=1
export TRIPS_TART_CLAIM_POLL_SECONDS=0.1
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

export FAKE_SCENARIO=tonegate-only
assert_equal 'jai/tonegate' "$(next_repository)"
export FAKE_SCENARIO=trips-first
assert_equal 'jai/trips-frontend' "$(next_repository)"
export FAKE_SCENARIO=no-jobs
if next_repository >/dev/null; then
  print -u2 -- 'Expected no queued repository'
  exit 1
fi

assert_equal 20 "$minimum_root_free_gib"
runner_lookup 'jai/trips-frontend' 'page-two-runner'
assert_equal $'4343\tidle' "$REPLY"

(
  sleep 3
) &
fake_runner_pid=$!
runner_busy_state() { REPLY=busy; }
wait_for_runner_claim 'jai/trips-frontend' 'test-runner' "$fake_runner_pid"
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
assert_equal 23 "$REPLY"

export FAKE_VM_PRESENT=true
if delete_vm 'test-vm'; then
  print -u2 -- 'Expected Tart deletion to fail closed while the VM remains present'
  exit 1
fi
export FAKE_VM_PRESENT=false
delete_vm 'test-vm'
export FAKE_VM_INVENTORY_ERROR=true
if delete_vm 'test-vm'; then
  print -u2 -- 'Expected Tart deletion to fail closed when inventory verification fails'
  exit 1
fi

export FAKE_SCENARIO=incompatible-host
if next_repository >/dev/null; then
  print -u2 -- 'Expected a job with an incompatible host label to be rejected'
  exit 1
fi

print -r -- 'Tart controller repository selection passed.'
