#!/bin/zsh
set -eu

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Capacity differs per host; shared with the Lima wrapper.
readonly host_config="/Users/jai/.config/trips-ci/host.env"
if [[ -r "$host_config" ]]; then
  set -a
  source "$host_config"
  set +a
fi

export TART_HOME="${TART_HOME:-/Users/jai/.tart}"
export TRIPS_TART_RUNNER_HOST_LABEL="borg-cube-03"
export TRIPS_TART_RUNNER_NAME_PREFIX="borg-cube-03-tart"
export TRIPS_TART_WORK_DISK_DIRECTORY="${TRIPS_TART_WORK_DISK_DIRECTORY:-/Users/jai/.local/share/trips-tart-runner/work-disks}"
export TRIPS_TART_NETWORK_MODE="${TRIPS_TART_NETWORK_MODE:-shared}"
export TRIPS_TART_ALLOWED_CORESIDENT_VMS="${TRIPS_TART_ALLOWED_CORESIDENT_VMS:-atlas-eve-alpha}"
exec /Users/jai/.local/bin/trips-tart-runner-controller
