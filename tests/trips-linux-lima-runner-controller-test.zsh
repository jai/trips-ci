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

export TRIPS_LINUX_RUNNER_CONTROLLER_LIBRARY_ONLY=true
export TRIPS_LINUX_LIMA_SLOT=a
export TRIPS_LINUX_LIMA_GH_CLI="$fake_gh"
export TRIPS_LINUX_LIMA_REPOSITORIES='jai/tonegate'
export TRIPS_LINUX_LIMA_CLAIM_TIMEOUT_SECONDS=1
export TRIPS_LINUX_LIMA_CLAIM_POLL_SECONDS=0.1
source "${repo_root}/scripts/trips-linux-lima-runner-controller.zsh"

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

print -r -- 'Linux Lima controller selection and claim lifecycle passed.'
