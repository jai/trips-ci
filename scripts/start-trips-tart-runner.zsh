#!/bin/zsh
set -eu

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

export TART_HOME="${TART_HOME:-/Users/jai/.tart}"
export TRIPS_TART_RUNNER_HOST_LABEL="borg-cube-03"
export TRIPS_TART_RUNNER_NAME_PREFIX="borg-cube-03-tart"
export TRIPS_TART_WORK_DISK_DIRECTORY="${TRIPS_TART_WORK_DISK_DIRECTORY:-/Users/jai/.local/share/trips-tart-runner/work-disks}"
exec /Users/jai/.local/bin/trips-tart-runner-controller
