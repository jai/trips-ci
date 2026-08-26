#!/bin/zsh
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly base_vm="${TRIPS_TART_BASE_VM:-trips-runner-base-next}"
readonly source_image="${TRIPS_TART_BASE_SOURCE_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-xcode:latest}"
readonly base_cpus="${TRIPS_TART_BASE_CPUS:-4}"
readonly base_memory_mb="${TRIPS_TART_BASE_MEMORY_MB:-16384}"
readonly base_disk_gib="${TRIPS_TART_BASE_DISK_GIB:-120}"
readonly minimum_root_free_gib="${TRIPS_TART_MINIMUM_ROOT_FREE_GIB:-5}"
readonly tart_cli="${TRIPS_TART_CLI:-/opt/homebrew/bin/tart}"

timestamp() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
}

phase() {
  print -- "$(timestamp) phase=$1"
}

base_name_is_safe() {
  [[ "$1" != trips-runner-base && "$1" != trips-runner-base-pre-apfs-expand ]]
}

base_root_preflight_command() {
  printf '%s' 'set -e; test "$(df -g / | awk '\''NR == 2 {print $4}'\'')" -ge "${TRIPS_TART_MINIMUM_ROOT_FREE_GIB:-5}"; xcodebuild -version >/dev/null; java -version >/dev/null 2>&1; test -x /Users/admin/actions-runner/bin/Runner.Listener; xcrun simctl list runtimes | grep -q "iOS"'
}

verify_base() {
  "$tart_cli" list --source local --quiet | /usr/bin/grep -qx "$base_vm" || {
    print -u2 -- "Candidate Tart base is missing: ${base_vm}"
    return 1
  }
  phase guest-root-preflight
  "$tart_cli" exec "$base_vm" /bin/zsh -lc "$(base_root_preflight_command)"
  phase guest-root-preflight-complete
}

main() {
  if [[ "${1:-}" == --verify ]]; then
    verify_base
    return
  fi
  base_name_is_safe "$base_vm" || {
    print -u2 -- "Refusing to overwrite a live or rollback Tart base: ${base_vm}"
    return 1
  }
  "$tart_cli" list --source local --quiet | /usr/bin/grep -qx "$base_vm" && {
    print -u2 -- "Candidate Tart base already exists: ${base_vm}"
    return 1
  }

  phase clone-source-image
  "$tart_cli" clone "$source_image" "$base_vm"
  phase configure-candidate
  "$tart_cli" set "$base_vm" --cpu "$base_cpus" --memory "$base_memory_mb" --disk-size "$base_disk_gib"
  phase candidate-created
  print -- "Created ${base_vm} from ${source_image}."
}

if [[ "${TRIPS_TART_BASE_LIBRARY_ONLY:-false}" != true ]]; then
  main "$@"
fi
