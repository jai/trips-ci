#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly required_volume="/Volumes/mac-mini-external"
readonly tart_home="${required_volume}/tart"
readonly controller="/Users/jai/.local/bin/trips-linux-tart-runner-controller"

if ! /sbin/mount | /usr/bin/grep -Fq " on ${required_volume} ("; then
  exit 0
fi

if /usr/bin/pgrep -f '^/bin/zsh /Users/jai/.local/bin/trips-linux-tart-runner-controller$' >/dev/null; then
  exit 0
fi

# launchd processes are denied direct removable-volume access by macOS TCC.
# Re-open this command in Terminal, whose logged-in user context is authorized.
if [[ "${TERM_PROGRAM:-}" != "Apple_Terminal" ]]; then
  /usr/bin/open -gj -a Terminal "$0"
  exit 0
fi

export TART_HOME="$tart_home"
export TRIPS_LINUX_TART_REQUIRED_VOLUME="$required_volume"
exec "$controller"
