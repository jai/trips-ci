#!/bin/zsh
set -eu

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly controller="/Users/jai/.local/bin/trips-linux-lima-runner-controller"
readonly slot="${TRIPS_LINUX_LIMA_SLOT:?TRIPS_LINUX_LIMA_SLOT must be a or b}"

if [[ "$slot" != "a" && "$slot" != "b" ]]; then
  print -u2 -- "TRIPS_LINUX_LIMA_SLOT must be a or b"
  exit 1
fi

export LIMA_HOME="${LIMA_HOME:-/Users/jai/.lima}"
exec "$controller"
