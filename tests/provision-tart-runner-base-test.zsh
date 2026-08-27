#!/bin/zsh
set -eu

repo_root="${0:A:h:h}"
mkdir -p "${repo_root}/tmp"
test_directory=$(mktemp -d "${repo_root}/tmp/tart-base-provision-test.XXXXXX")
trap '/bin/rm -rf -- "$test_directory"' EXIT
fake_tart="${test_directory}/tart"
fake_log="${test_directory}/tart.log"
cat > "$fake_tart" <<'SCRIPT'
#!/bin/zsh
set -eu
print -r -- "$*" >> "$FAKE_TART_LOG"
if [[ "$1" == list ]]; then
  [[ "${FAKE_BASE_EXISTS:-false}" == true ]] && print -r -- "${FAKE_BASE_NAME}"
fi
SCRIPT
chmod 700 "$fake_tart"

export TRIPS_TART_BASE_LIBRARY_ONLY=true
source "${repo_root}/scripts/provision-tart-runner-base.zsh"

base_name_is_safe trips-runner-base-next
if base_name_is_safe trips-runner-base; then
  print -u2 -- 'Expected the live base name to be rejected'
  exit 1
fi
if base_name_is_safe trips-runner-base-pre-apfs-expand; then
  print -u2 -- 'Expected the rollback base name to be rejected'
  exit 1
fi

FAKE_TART_LOG="$fake_log" \
FAKE_BASE_NAME=trips-runner-base-next \
TRIPS_TART_BASE_VM=trips-runner-base-next \
TRIPS_TART_CLI="$fake_tart" \
TRIPS_TART_BASE_LIBRARY_ONLY=false \
zsh "${repo_root}/scripts/provision-tart-runner-base.zsh"
[[ "$(sed -n '1p' "$fake_log")" == 'list --source local --quiet' ]]
[[ "$(sed -n '2p' "$fake_log")" == 'clone ghcr.io/cirruslabs/macos-tahoe-xcode:latest trips-runner-base-next' ]]
[[ "$(sed -n '3p' "$fake_log")" == 'set trips-runner-base-next --cpu 4 --memory 16384 --disk-size 120' ]]

: > "$fake_log"
FAKE_TART_LOG="$fake_log" \
FAKE_BASE_NAME=trips-runner-base-next \
FAKE_BASE_EXISTS=true \
TRIPS_TART_BASE_VM=trips-runner-base-next \
TRIPS_TART_CLI="$fake_tart" \
TRIPS_TART_BASE_LIBRARY_ONLY=false \
zsh "${repo_root}/scripts/provision-tart-runner-base.zsh" --verify
[[ "$(sed -n '1p' "$fake_log")" == 'list --source local --quiet' ]]
[[ "$(sed -n '2p' "$fake_log")" == exec\ trips-runner-base-next\ /bin/zsh\ -lc\ * ]]
grep -q '/opt/homebrew/bin/pod --version' "$fake_log"

if FAKE_TART_LOG="$fake_log" \
  FAKE_BASE_NAME=trips-runner-base-next \
  FAKE_BASE_EXISTS=true \
  TRIPS_TART_BASE_VM=trips-runner-base-next \
  TRIPS_TART_CLI="$fake_tart" \
  TRIPS_TART_BASE_LIBRARY_ONLY=false \
  zsh "${repo_root}/scripts/provision-tart-runner-base.zsh"; then
  print -u2 -- 'Expected an existing candidate base to be rejected'
  exit 1
fi

print -- 'Tart base provisioning safeguards passed.'
