#!/bin/zsh
set -eu

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly required_volume="${GITHUB_CI_LIMA_REQUIRED_VOLUME:-/Volumes/mac-mini-external}"
readonly lima_home="${LIMA_HOME:-${required_volume}/lima}"
readonly instance="${GITHUB_CI_LIMA_INSTANCE:-github-ci}"

export LIMA_HOME="$lima_home"

while ! /sbin/mount | /usr/bin/grep -Fq " on ${required_volume} ("; do
  /bin/sleep 10
done

status_json=$(/opt/homebrew/bin/limactl list "$instance" --json 2>/dev/null || true)
if [[ -n "$status_json" ]] && [[ "$(printf '%s' "$status_json" | /usr/bin/jq -r '.status // ""')" == "Running" ]]; then
  host_agent_pid=$(printf '%s' "$status_json" | /usr/bin/jq -r '.hostAgentPID // 0')
  while [[ "$host_agent_pid" == <1-> ]] && /bin/kill -0 "$host_agent_pid" 2>/dev/null; do
    /bin/sleep 30
  done
fi

exec /opt/homebrew/bin/limactl start "$instance" --foreground
