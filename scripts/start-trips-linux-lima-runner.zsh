#!/bin/zsh
set -eu

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly controller="/Users/jai/.local/bin/trips-linux-lima-runner-controller"
readonly slot="${TRIPS_LINUX_LIMA_SLOT:?TRIPS_LINUX_LIMA_SLOT must be a, b, c or d}"
readonly host_config="/Users/jai/.config/trips-ci/host.env"

if [[ "$slot" != [abcd] ]]; then
  print -u2 -- "TRIPS_LINUX_LIMA_SLOT must be a, b, c or d"
  exit 1
fi

# Capacity differs per host; the laptop keeps the controller defaults.
if [[ -r "$host_config" ]]; then
  set -a
  source "$host_config"
  set +a
fi

export LIMA_HOME="${LIMA_HOME:-/Users/jai/.lima}"
exec "$controller"
