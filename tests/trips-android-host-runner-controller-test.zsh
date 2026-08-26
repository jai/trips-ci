#!/bin/zsh
set -eu

repo_root="${0:A:h:h}"
test_root=$(mktemp -d "${repo_root}/tmp/android-host-controller.XXXXXX")
trap '/bin/rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/sdk/emulator"
cat >"$test_root/sdk/emulator/emulator" <<'SCRIPT'
#!/bin/zsh
case "${FAKE_ACCEL:-ok}" in
  ok) print -r -- $'accel: 0\nHypervisor.Framework is installed and usable.' ;;
  header-only) print -r -- 'accel: 0' ;;
  unavailable) print -r -- $'accel: 1\nHypervisor.Framework is not usable.' ;;
esac
SCRIPT
chmod 700 "$test_root/sdk/emulator/emulator"

fake_gh="$test_root/gh"
cat >"$fake_gh" <<'SCRIPT'
#!/bin/zsh
set -eu

request="$*"
case "${FAKE_GH_SCENARIO:-runner}" in
  queue-match)
    if [[ "$request" == *'actions/runs?status=queued'* ]]; then
      print -r -- 123
    elif [[ "$request" == *'actions/runs/123/jobs?'* ]]; then
      print -r -- yes
    else
      exit 64
    fi
    ;;
  runner)
    if [[ "$request" == *'registration-token'* ]]; then
      print -r -- test-registration-token
    elif [[ "$request" == *'actions/runners?per_page=100'* ]]; then
      print -r -- 733
    elif [[ "$request" == *'-X DELETE'* && "$request" == *'actions/runners/733'* ]]; then
      print -r -- delete >>"$FAKE_GH_LOG"
    else
      exit 64
    fi
    ;;
  *)
    exit 64
    ;;
esac
SCRIPT
chmod 700 "$fake_gh"

mkdir -p "$test_root/runner-root"
cat >"$test_root/runner-root/config.sh" <<'SCRIPT'
#!/bin/zsh
set -eu
print -r -- config >>"$FAKE_RUNNER_LOG"
exit "${FAKE_CONFIG_EXIT:-0}"
SCRIPT
cat >"$test_root/runner-root/run.sh" <<'SCRIPT'
#!/bin/zsh
set -eu
print -r -- run >>"$FAKE_RUNNER_LOG"
exit "${FAKE_RUN_EXIT:-0}"
SCRIPT
chmod 700 "$test_root/runner-root/config.sh" "$test_root/runner-root/run.sh"

TRIPS_ANDROID_CONTROLLER_LIBRARY_ONLY=true \
  TRIPS_ANDROID_SDK_ROOT="$test_root/sdk" \
  TRIPS_ANDROID_GH_CLI="$fake_gh" \
  TRIPS_ANDROID_RUNNER_ROOT="$test_root/runner-root" \
  TRIPS_ANDROID_WORK_ROOT="$test_root/work" \
  source "$repo_root/scripts/trips-android-host-runner-controller.zsh"
[[ -x "$repo_root/scripts/start-trips-android-host-runner.zsh" ]]
[[ -x "$repo_root/scripts/trips-android-host-runner-controller.zsh" ]]
FAKE_ACCEL=ok emulator_acceleration_healthy
if FAKE_ACCEL=header-only emulator_acceleration_healthy; then
  print -u2 -- 'acceleration header without usability text must fail'
  exit 1
fi
if FAKE_ACCEL=unavailable emulator_acceleration_healthy; then
  print -u2 -- 'unavailable acceleration must fail'
  exit 1
fi

if TRIPS_ANDROID_CONTROLLER_LIBRARY_ONLY=true TRIPS_ANDROID_GH_CLI=/usr/bin/true \
  zsh -c 'source "$1"; queued_android_job_exists' zsh "$repo_root/scripts/trips-android-host-runner-controller.zsh"; then
  print -u2 -- 'an empty queued-run response must not start an Android runner'
  exit 1
fi
if TRIPS_ANDROID_CONTROLLER_LIBRARY_ONLY=true TRIPS_ANDROID_GH_CLI=/usr/bin/false \
  zsh -c 'source "$1"; queued_android_job_exists' zsh "$repo_root/scripts/trips-android-host-runner-controller.zsh"; then
  print -u2 -- 'a queued-run API failure must fail closed'
  exit 1
fi
FAKE_GH_SCENARIO=queue-match queued_android_job_exists

runner_log="$test_root/runner.log"
gh_log="$test_root/gh.log"
: >"$runner_log"
: >"$gh_log"
if FAKE_GH_SCENARIO=runner FAKE_RUNNER_LOG="$runner_log" FAKE_GH_LOG="$gh_log" FAKE_CONFIG_EXIT=23 run_one_job; then
  print -u2 -- 'a failed runner configuration must fail the one-job cycle'
  exit 1
fi
grep -qx config "$runner_log"
if grep -qx run "$runner_log"; then
  print -u2 -- 'runner execution must not start after configuration failure'
  exit 1
fi
grep -qx delete "$gh_log"

: >"$runner_log"
: >"$gh_log"
if FAKE_GH_SCENARIO=runner FAKE_RUNNER_LOG="$runner_log" FAKE_GH_LOG="$gh_log" FAKE_RUN_EXIT=24 run_one_job; then
  print -u2 -- 'a failed runner process must fail the one-job cycle'
  exit 1
fi
grep -qx config "$runner_log"
grep -qx run "$runner_log"
grep -qx delete "$gh_log"

print -r -- 'Android host controller checks passed.'
