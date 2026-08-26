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
TRIPS_ANDROID_CONTROLLER_LIBRARY_ONLY=true \
  TRIPS_ANDROID_SDK_ROOT="$test_root/sdk" \
  source "$repo_root/scripts/trips-android-host-runner-controller.zsh"
FAKE_ACCEL=ok emulator_acceleration_healthy
if FAKE_ACCEL=header-only emulator_acceleration_healthy; then
  print -u2 -- 'acceleration header without usability text must fail'
  exit 1
fi
if FAKE_ACCEL=unavailable emulator_acceleration_healthy; then
  print -u2 -- 'unavailable acceleration must fail'
  exit 1
fi
print -r -- 'Android host controller acceleration checks passed.'
