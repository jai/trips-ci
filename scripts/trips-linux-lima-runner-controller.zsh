#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly app_id="${TRIPS_TART_GITHUB_APP_ID:-4452026}"
readonly installation_id="${TRIPS_TART_GITHUB_INSTALLATION_ID:-150444191}"
readonly repositories="${TRIPS_LINUX_LIMA_REPOSITORIES:-jai/trips-api,jai/trips-frontend,jai/trips-email-ingest-worker,jai/trips-infra,jai/trips,jai/trips-fastlane,jai/openclaw-prompts,jai/tonegate}"
readonly -a repository_list=(${(s:,:)repositories})
readonly base_vm="${TRIPS_LINUX_LIMA_BASE_VM:-trips-linux-runner-base}"
readonly slot="${TRIPS_LINUX_LIMA_SLOT:?TRIPS_LINUX_LIMA_SLOT must be a or b}"
readonly cpus="${TRIPS_LINUX_LIMA_CPUS:-3}"
readonly memory_gib="${TRIPS_LINUX_LIMA_MEMORY_GIB:-8}"
readonly runner_root="/opt/actions-runner"
readonly runner_name_prefix="${TRIPS_LINUX_LIMA_RUNNER_NAME_PREFIX:-borg-cube-03-lima-${slot}}"
readonly runner_labels="jai-ci,jai-ci-tonegate"
readonly private_key="/Users/jai/.config/trips-tart-runner/github-app-private-key.pem"
readonly log_directory="/Users/jai/Library/Logs/trips-linux-lima-runner"
readonly selection_lock="${LIMA_HOME:-/Users/jai/.lima}/.trips-linux-runner-selection-lock"
readonly gh_cli="${TRIPS_LINUX_LIMA_GH_CLI:-/opt/homebrew/bin/gh}"
readonly curl_cli="${TRIPS_LINUX_LIMA_CURL_CLI:-/usr/bin/curl}"
readonly lima_cli="${TRIPS_LINUX_LIMA_CLI:-/opt/homebrew/bin/limactl}"
readonly claim_timeout_seconds="${TRIPS_LINUX_LIMA_CLAIM_TIMEOUT_SECONDS:-300}"
readonly claim_poll_seconds="${TRIPS_LINUX_LIMA_CLAIM_POLL_SECONDS:-2}"
readonly idle_scan_interval_seconds="${TRIPS_LINUX_LIMA_IDLE_SCAN_INTERVAL_SECONDS:-30}"

typeset -g installation_token_value=""
typeset -g installation_token_expires_at=0
typeset -g selected_repository=""

export LIMA_HOME="${LIMA_HOME:-/Users/jai/.lima}"

timestamp() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  print -r -- "$(timestamp) slot=${slot} $*"
}

base64url() {
  setopt local_options pipe_fail
  /usr/bin/openssl base64 -A | /usr/bin/tr '+/' '-_' | /usr/bin/tr -d '='
}

github_jwt() {
  setopt local_options pipe_fail
  local now issued_at expires_at header payload unsigned signature
  now=$(/bin/date +%s)
  issued_at=$((now - 60))
  expires_at=$((now + 540))
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url) || return 1
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$issued_at" "$expires_at" "$app_id" | base64url) || return 1
  unsigned="${header}.${payload}"
  signature=$(printf '%s' "$unsigned" | /usr/bin/openssl dgst -sha256 -sign "$private_key" | base64url) || return 1
  printf '%s.%s' "$unsigned" "$signature"
}

installation_token() {
  setopt local_options pipe_fail
  local now jwt
  now=$(/bin/date +%s)
  if [[ -n "$installation_token_value" ]] && (( now < installation_token_expires_at )); then
    REPLY="$installation_token_value"
    return 0
  fi
  jwt=$(github_jwt) || return 1
  installation_token_value=$("$curl_cli" -fsS --connect-timeout 10 --max-time 20 -X POST \
    -H "Authorization: Bearer $jwt" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/app/installations/${installation_id}/access_tokens" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') || return 1
  installation_token_expires_at=$((now + 480))
  REPLY="$installation_token_value"
}

registration_token() {
  local repository="$1" token
  installation_token || return 1
  token="$REPLY"
  REPLY=$("$curl_cli" -fsS --connect-timeout 10 --max-time 20 -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners/registration-token" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') || return 1
}

repository_is_private() {
  local repository="$1" token
  installation_token || return 1
  token="$REPLY"
  "$curl_cli" -fsS --connect-timeout 10 --max-time 20 \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}" |
    /usr/bin/python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("private") is True else 1)'
}

runner_lookup() {
  local repository="$1" runner_name="$2" token page response result count
  installation_token || return 1
  token="$REPLY"
  page=1
  while true; do
    response=$("$curl_cli" -fsS --connect-timeout 10 --max-time 20 \
      -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "https://api.github.com/repos/${repository}/actions/runners?per_page=100&page=${page}") || return 1
    result=$(printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys
data=json.load(sys.stdin); name=sys.argv[1]; runner=next((r for r in data.get("runners",[]) if r.get("name") == name), None)
print((str(runner["id"])+"\t"+("busy" if runner.get("busy") else "idle")) if runner else "")' "$runner_name") || return 1
    if [[ -n "$result" ]]; then REPLY="$result"; return 0; fi
    count=$(printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("runners",[])))') || return 1
    (( count < 100 )) && break
    page=$((page + 1))
  done
  REPLY=$'\tmissing'
}

runner_busy_state() {
  runner_lookup "$1" "$2" || return 1
  REPLY="${REPLY#*$'\t'}"
}

delete_runner_registration() {
  local repository="$1" runner_name="$2" id token
  runner_lookup "$repository" "$runner_name" || return 0
  id="${REPLY%%$'\t'*}"
  [[ -n "$id" ]] || return 0
  installation_token || return 1
  token="$REPLY"
  "$curl_cli" -fsS --connect-timeout 10 --max-time 20 -X DELETE \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners/${id}" >/dev/null
}

repository_workflow_runs() {
  local repository="$1" run_status
  for run_status in queued in_progress; do
    "$gh_cli" api \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      --paginate \
      "repos/${repository}/actions/runs?status=${run_status}&per_page=100" \
      --jq '.workflow_runs[] | [.id, .created_at, .head_repository.full_name] | @tsv' || return 2
  done
}

workflow_run_oldest_queued_job_timestamp() {
  setopt local_options pipe_fail
  local repository="$1" run_id="$2"
  "$gh_cli" api \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    --paginate --slurp \
    "repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" |
    /usr/bin/python3 -c 'import json,sys
base={"self-hosted","linux","arm64"}; supported=({"jai-ci"},{"jai-ci-tonegate"})
jobs=[job for page in json.load(sys.stdin) for job in page.get("jobs",[])]
matches=[job.get("created_at","") for job in jobs if job.get("status") == "queued" and ({str(label).lower() for label in job.get("labels",[])}-base) in supported and base <= {str(label).lower() for label in job.get("labels",[])} and job.get("created_at")]
print(min(matches) if matches else "")' || return 2
}

repository_oldest_queued_job_timestamp() {
  local repository="$1" runs run_id run_created_at head_repository queued_at oldest_queued_at
  oldest_queued_at=""
  runs=$(repository_workflow_runs "$repository") || return 2
  while IFS=$'\t' read -r run_id run_created_at head_repository; do
    [[ -n "$run_id" ]] || continue
    [[ "$head_repository" == "$repository" ]] || continue
    queued_at=$(workflow_run_oldest_queued_job_timestamp "$repository" "$run_id") || return 2
    [[ -n "$queued_at" ]] || continue
    if [[ -z "$oldest_queued_at" || "$queued_at" < "$oldest_queued_at" ]]; then
      oldest_queued_at="$queued_at"
    fi
  done <<< "$runs"
  [[ -n "$oldest_queued_at" ]] || return 1
  print -r -- "$oldest_queued_at"
}

next_repository() {
  local repository queued_at oldest_queued_at
  local -i lookup_status
  selected_repository=""
  oldest_queued_at=""
  for repository in "${repository_list[@]}"; do
    if queued_at=$(repository_oldest_queued_job_timestamp "$repository"); then
      :
    else
      lookup_status=$?
      (( lookup_status == 1 )) && continue
      return "$lookup_status"
    fi
    if [[ -z "$oldest_queued_at" || "$queued_at" < "$oldest_queued_at" ]]; then
      selected_repository="$repository"
      oldest_queued_at="$queued_at"
    fi
  done
  [[ -n "$selected_repository" ]]
}

wait_for_runner_claim() {
  local repository="$1" runner_name="$2" runner_pid="$3" started_at now state
  started_at=$(/bin/date +%s)
  while /bin/kill -0 "$runner_pid" 2>/dev/null; do
    if runner_busy_state "$repository" "$runner_name"; then
      state="$REPLY"
      [[ "$state" == busy ]] && return 0
    else
      state=unknown
      log "unable to verify ${runner_name} claim state; preserving runner"
    fi
    now=$(/bin/date +%s)
    if (( now - started_at >= claim_timeout_seconds )) && [[ "$state" == idle || "$state" == missing ]]; then
      return 2
    fi
    /bin/sleep "$claim_poll_seconds"
  done
  return 1
}

acquire_selection_lock() {
  local owner
  while ! /bin/mkdir "$selection_lock" 2>/dev/null; do
    owner="$(/bin/cat "${selection_lock}/pid" 2>/dev/null || true)"
    if [[ "$owner" == <1-> ]] && ! /bin/kill -0 "$owner" 2>/dev/null; then
      /bin/rm -rf "$selection_lock"
      continue
    fi
    /bin/sleep 2
  done
  printf '%s\n' "$$" > "${selection_lock}/pid"
}

release_selection_lock() {
  local owner
  owner="$(/bin/cat "${selection_lock}/pid" 2>/dev/null || true)"
  if [[ "$owner" == "$$" ]]; then
    /bin/rm -rf "$selection_lock"
  fi
}

delete_vm() {
  local vm_name="$1" inventory
  "$lima_cli" stop --force "$vm_name" >/dev/null 2>&1 || true
  "$lima_cli" delete --force "$vm_name" >/dev/null 2>&1 || true
  inventory=$("$lima_cli" list --json 2>/dev/null) || {
    log "unable to verify deletion of ${vm_name}"
    return 1
  }
  if printf '%s\n' "$inventory" | /usr/bin/python3 -c 'import json,sys
name=sys.argv[1]
raise SystemExit(0 if any(json.loads(line).get("name") == name for line in sys.stdin if line.strip()) else 1)' "$vm_name"; then
    log "failed to delete ${vm_name}"
    return 1
  fi
}

list_ephemeral_vms() {
  local inventory
  inventory=$("$lima_cli" list --json 2>/dev/null) || {
    log "unable to inventory Lima VMs"
    return 1
  }
  printf '%s\n' "$inventory" | /usr/bin/python3 -c 'import json,sys
for line in sys.stdin:
    if line.strip():
        name=json.loads(line)["name"]
        if name.startswith("trips-linux-runner-") and "-job-" in name:
            print(name)'
}

cleanup_runner_vm() {
  local repository="$1" runner_name="$2" vm_name="$3"
  log "deleting ${vm_name}"
  delete_vm "$vm_name" || return 1
  delete_runner_registration "$repository" "$runner_name" || true
}

resolve_runner_status() {
  local claim_result="$1" runner_pid="$2" runner_name="$3"
  REPLY=1
  case "$claim_result" in
    0)
      log "${runner_name} claimed a job"
      release_selection_lock
      REPLY=0
      wait "$runner_pid" || REPLY=$?
      ;;
    1)
      REPLY=0
      wait "$runner_pid" || REPLY=$?
      ;;
    2)
      log "${runner_name} remained idle; removing it"
      /bin/kill "$runner_pid" 2>/dev/null || true
      wait "$runner_pid" >/dev/null 2>&1 || true
      REPLY=0
      ;;
    *)
      log "unexpected runner claim result ${claim_result}"
      return 1
      ;;
  esac
}

run_one_ephemeral_runner() {
  local repository="$1" suffix vm_name token runner_name runner_pid runner_status
  suffix="$(/bin/date -u '+%Y%m%d%H%M%S')-$$"
  vm_name="trips-linux-runner-${slot}-job-${suffix}"
  runner_name="${runner_name_prefix}-${suffix}"
  runner_pid=""
  runner_status=1

  if ! repository_is_private "$repository"; then
    log "refusing non-private or unavailable repository ${repository}"
    return 1
  fi

  log "cloning ${base_vm} to ${vm_name} for ${repository}"
  "$lima_cli" clone "$base_vm" "$vm_name" \
    --cpus="$cpus" --memory="$memory_gib" --mount-none --start --tty=false || return 1

  cleanup() {
    cleanup_runner_vm "$repository" "$runner_name" "$vm_name"
  }
  trap 'release_selection_lock; cleanup || exit 1; exit 130' INT TERM

  {
    "$lima_cli" shell "$vm_name" -- \
      bash -lc 'set -e; test "$(nproc)" = 3; test "$(free -g | awk '\''/^Mem:/{print $2}'\'')" -ge 7; docker info >/dev/null; docker compose version; test -x /opt/actions-runner/bin/Runner.Listener' || return 1

    registration_token "$repository" || return 1
    token="$REPLY"
    log "registering ${runner_name} for ${repository}"
    printf '%s\n' "$token" | "$lima_cli" shell "$vm_name" -- \
      bash -lc "IFS= read -r registration_token; cd '$runner_root'; ./config.sh --unattended --ephemeral --disableupdate --url 'https://github.com/${repository}' --token \"\$registration_token\" --name '$runner_name' --labels '$runner_labels' --work _work; exec ./run.sh" &
    runner_pid=$!
    wait_for_runner_claim "$repository" "$runner_name" "$runner_pid"
    local claim_result=$?
    resolve_runner_status "$claim_result" "$runner_pid" "$runner_name" || return 1
    runner_status="$REPLY"
  } always {
    release_selection_lock
    trap - INT TERM
    cleanup || return 1
  }
  return "$runner_status"
}

main() {
  local repository stale_vms
  local -i scan_status
  umask 077
  mkdir -p "$log_directory"
  if [[ "$slot" != "a" && "$slot" != "b" ]]; then
    log "TRIPS_LINUX_LIMA_SLOT must be a or b"
    return 1
  fi
  if [[ "$cpus" != 3 || "$memory_gib" != 8 ]]; then
    log "resource contract requires 3 CPUs and 8 GiB per Linux slot"
    return 1
  fi
  if [[ ! -s "$private_key" ]]; then
    log "GitHub App private key is missing"
    return 1
  fi
  if ! "$lima_cli" list "$base_vm" --json 2>/dev/null |
    /usr/bin/grep -q '"status":"Stopped"'; then
    log "stopped Lima base ${base_vm} is missing"
    return 1
  fi
  if ! "$gh_cli" auth status >/dev/null 2>&1; then
    log "GitHub CLI authentication is unavailable"
    return 1
  fi
  for repository in ${(s:,:)repositories}; do
    if ! repository_is_private "$repository"; then
      log "refusing non-private or unavailable repository ${repository}"
      return 1
    fi
  done

  stale_vms=$(list_ephemeral_vms) || return 1
  while IFS= read -r stale_vm; do
    [[ "$stale_vm" == trips-linux-runner-${slot}-job-* ]] || continue
    log "removing stale ephemeral VM ${stale_vm}"
    delete_vm "$stale_vm" || return 1
  done <<< "$stale_vms"

  while true; do
    acquire_selection_lock
    if next_repository; then
      repository="$selected_repository"
      if run_one_ephemeral_runner "$repository"; then
        log "ephemeral runner completed a job for ${repository}"
      else
        log "ephemeral runner cycle failed for ${repository}; retrying in 15 seconds"
        /bin/sleep 15
      fi
    else
      scan_status=$?
      # Keep the shared lock while idle so the second slot cannot duplicate the
      # repository scan and exhaust the authenticated GitHub API quota.
      if (( scan_status == 1 )); then
        /bin/sleep "$idle_scan_interval_seconds"
      else
        log "GitHub queue scan failed; retrying in 15 seconds"
        /bin/sleep 15
      fi
      release_selection_lock
    fi
  done
}

if [[ "${TRIPS_LINUX_RUNNER_CONTROLLER_LIBRARY_ONLY:-false}" != true ]]; then
  main
fi
