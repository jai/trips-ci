#!/bin/zsh
# Pages Jai once when CI has been unable to reach GitHub for an hour.
set -u
setopt pipe_fail

readonly state_directory="${HOME}/.local/state/trips-ci-health"
readonly failing_since_file="${state_directory}/failing-since"
readonly alert_id_file="${state_directory}/alert-id"
readonly page_after_seconds=3600
readonly manual_url="https://github.com/jai/trips/blob/main/docs/ci-runners.md"

all_ready() {
  jq -e '.status == "ok" and ([.scale_sets[].ready] | all)' >/dev/null
}

# runscaler's own health can stay ok while the VM has no DNS, so probe GitHub from the VM.
linux_healthy() {
  gtimeout 60 colima ssh -p ci -- sh -c \
    'getent hosts github.com >/dev/null && curl -fsS -m 15 -o /dev/null https://github.com && curl -fsS -m 5 localhost:18080/healthz' \
    </dev/null 2>/dev/null | all_ready
}

ios_healthy() {
  curl -fsS -m 5 http://127.0.0.1:18081/healthz 2>/dev/null | all_ready
}

pager_setting() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${HOME}/.credentials/agent-pager"
}

pager_post() {
  local route="$1" body="$2" token url
  token=$(pager_setting AGENT_TOKEN_CLAUDE_BORG_CUBE_03)
  url=$(pager_setting WORKER_URL)
  curl -fsS -m 20 -X POST "${url}${route}" -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' -d "$body"
}

send_page() {
  local failed="$1" body response
  body=$(jq -n --arg failed "$failed" --arg url "$manual_url" '{
    title: "Trips CI cannot reach GitHub",
    severity: "info",
    body: ("CI on borg-cube-03 has been unhealthy for an hour. Failing now: \($failed). Jobs queued during an outage need a cancel and re-run."),
    context_url: $url
  }')
  response=$(pager_post /alert "$body") || return 1
  print -r -- "$response" | jq -r '.id' > "$alert_id_file"
}

main() {
  local failed=() now failing_since alert_id
  mkdir -p "$state_directory"
  linux_healthy || failed+=(Linux)
  ios_healthy || failed+=(iOS)
  now=$(/bin/date +%s)

  if (( ${#failed} == 0 )); then
    if [[ -s "$alert_id_file" ]]; then
      read -r alert_id < "$alert_id_file"
      pager_post "/alert/${alert_id}/resolve" '{}' >/dev/null || return 1
    fi
    /bin/rm -f "$failing_since_file" "$alert_id_file"
    return 0
  fi

  [[ -s "$failing_since_file" ]] || print -r -- "$now" > "$failing_since_file"
  read -r failing_since < "$failing_since_file"
  print -r -- "$(/bin/date -u +%FT%TZ) failing: ${failed[*]} since ${failing_since}"
  if (( now - failing_since >= page_after_seconds )) && [[ ! -s "$alert_id_file" ]]; then
    send_page "${(j: and :)failed}"
  fi
}

main
