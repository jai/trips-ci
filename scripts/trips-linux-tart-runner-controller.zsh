#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly app_id="${TRIPS_TART_GITHUB_APP_ID:-4452026}"
readonly installation_id="${TRIPS_TART_GITHUB_INSTALLATION_ID:-150444191}"
readonly repositories="${TRIPS_LINUX_TART_REPOSITORIES:-jai/trips-api,jai/trips-frontend,jai/trips-email-ingest-worker,jai/trips-infra,jai/trips,jai/trips-ci,jai/trips-fastlane,jai/openclaw-prompts}"
readonly base_vm="${TRIPS_LINUX_TART_BASE_VM:-trips-linux-runner-base}"
readonly base_memory_mb="${TRIPS_LINUX_TART_BASE_MEMORY_MB:-4096}"
readonly runner_root="/opt/actions-runner"
readonly runner_name_prefix="${TRIPS_LINUX_TART_RUNNER_NAME_PREFIX:-jais-mac-mini-tart-linux}"
readonly runner_labels="jai-ci"
readonly private_key="/Users/jai/.config/trips-tart-runner/github-app-private-key.pem"
readonly ssh_key="/Users/jai/.config/trips-tart-runner/runner-controller-ed25519"
readonly log_directory="/Users/jai/Library/Logs/trips-linux-tart-runner"
readonly required_volume="${TRIPS_LINUX_TART_REQUIRED_VOLUME:-}"
readonly lock_directory="${log_directory}/controller.lock"
readonly lane_lock_directory="/Users/jai/Library/Logs/trips-tart-runner-lane.lock"

typeset -g github_installation_token=""
typeset -g github_installation_token_expires_at=0

export TART_HOME="${TART_HOME:-/Users/jai/.tart}"

mkdir -p "$log_directory"

timestamp() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  print -r -- "$(timestamp) $*"
}

acquire_lock() {
  local lock_path="$1" owner_pid="" candidate
  candidate="${lock_path}.$$"
  printf '%s\n' $$ >"$candidate"
  if /bin/ln "$candidate" "$lock_path" 2>/dev/null; then
    /bin/rm -f "$candidate"
    return 0
  fi
  /bin/rm -f "$candidate"
  [[ -r "$lock_path" ]] || return 1
  read -r owner_pid <"$lock_path"
  if [[ "$owner_pid" == <1-> ]] && /bin/kill -0 "$owner_pid" 2>/dev/null; then return 1; fi
  /bin/rm -f "$lock_path"
  acquire_lock "$lock_path"
}

release_lock() {
  local lock_path="$1" owner_pid=""
  [[ -r "$lock_path" ]] && read -r owner_pid <"$lock_path"
  [[ "$owner_pid" != $$ ]] || /bin/rm -f "$lock_path"
}

acquire_controller_lock() { acquire_lock "$lock_directory"; }
release_controller_lock() { release_lock "$lock_directory"; }
acquire_lane_lock() { acquire_lock "$lane_lock_directory"; }
release_lane_lock() { release_lock "$lane_lock_directory"; }

base64url() {
  /usr/bin/openssl base64 -A | /usr/bin/tr '+/' '-_' | /usr/bin/tr -d '='
}

github_jwt() {
  local now issued_at expires_at header payload unsigned signature
  now=$(/bin/date +%s)
  issued_at=$((now - 60))
  expires_at=$((now + 540))
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$issued_at" "$expires_at" "$app_id" | base64url)
  unsigned="${header}.${payload}"
  signature=$(printf '%s' "$unsigned" | /usr/bin/openssl dgst -sha256 -sign "$private_key" | base64url)
  printf '%s.%s' "$unsigned" "$signature"
}

ensure_installation_token() {
  local jwt now response
  now=$(/bin/date +%s)
  if [[ -n "$github_installation_token" ]] && (( now < github_installation_token_expires_at )); then
    return 0
  fi
  jwt=$(github_jwt) || return 1
  response=$(
    /usr/bin/curl -fsS -X POST \
      -H "Authorization: Bearer $jwt" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "https://api.github.com/app/installations/${installation_id}/access_tokens"
  ) || return 1
  github_installation_token=$(printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') || return 1
  github_installation_token_expires_at=$(( now + 3000 ))
}

github_api() {
  local method="$1" endpoint="$2"
  ensure_installation_token || return 1
  /usr/bin/curl -fsS -X "$method" \
    -H "Authorization: Bearer $github_installation_token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/${endpoint}"
}

registration_token() {
  local repository="$1"
  ensure_installation_token || return 1
  /usr/bin/curl -fsS -X POST \
    -H "Authorization: Bearer $github_installation_token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners/registration-token" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

repository_has_queued_job() {
  local repository="$1" run_id run_ids queued_job_count status
  run_ids=""
  for status in queued in_progress; do
    run_ids+=$(/opt/homebrew/bin/gh api \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "repos/${repository}/actions/runs?status=${status}&per_page=20" \
      --jq '.workflow_runs[].id') || return 1
    run_ids+=$'\n'
  done

  while IFS= read -r run_id; do
    [[ -n "$run_id" ]] || continue
    queued_job_count=$(
      /opt/homebrew/bin/gh api \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" \
        --jq '[.jobs[] | select(.status == "queued") | select((.labels | index("self-hosted")) and (.labels | index("linux")) and (.labels | index("arm64")) and (.labels | index("jai-ci")))] | length'
    ) || continue
    if [[ "$queued_job_count" == <1-> ]]; then
      return 0
    fi
  done <<<"$run_ids"
  return 1
}

user_api_has_headroom() {
  local remaining
  remaining=$(/opt/homebrew/bin/gh api rate_limit --jq '.resources.core.remaining') || return 1
  [[ "$remaining" == <1500-> ]]
}

next_repository() {
  local repository
  for repository in ${(s:,:)repositories}; do
    if repository_has_queued_job "$repository"; then
      printf '%s' "$repository"
      return 0
    fi
  done
  return 1
}

delete_vm() {
  local vm_name="$1" vm_list
  /opt/homebrew/bin/tart stop "$vm_name" >/dev/null 2>&1 || true
  /opt/homebrew/bin/tart delete "$vm_name" >/dev/null 2>&1 || true
  vm_list=$(/opt/homebrew/bin/tart list --source local --quiet) || return 1
  ! printf '%s\n' "$vm_list" | /usr/bin/grep -qx "$vm_name" || {
    log "failed to delete ${vm_name}"
    return 1
  }
}

runner_id() {
  local repository="$1" runner_name="$2"
  github_api GET "repos/${repository}/actions/runners?per_page=100" |
    RUNNER_NAME="$runner_name" /usr/bin/python3 -c 'import json,os,sys; print(next((runner["id"] for runner in json.load(sys.stdin)["runners"] if runner["name"] == os.environ["RUNNER_NAME"]), ""))'
}

runner_registration_state() {
  local repository="$1" runner_name="$2"
  github_api GET "repos/${repository}/actions/runners?per_page=100" |
    RUNNER_NAME="$runner_name" /usr/bin/python3 -c 'import json,os,sys; runner=next((r for r in json.load(sys.stdin)["runners"] if r["name"] == os.environ["RUNNER_NAME"]), None); print("missing" if runner is None else ("busy" if runner["busy"] else "idle"))' || print unreachable
}

runner_process_state() {
  local vm_ip="$1"
  local state
  state=$(/usr/bin/ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=3 \
    -o ServerAliveInterval=2 \
    -o ServerAliveCountMax=2 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -i "$ssh_key" \
    "admin@${vm_ip}" \
    "if /usr/bin/pgrep -f '^${runner_root}/bin/Runner.Worker ' >/dev/null; then printf '%s\\n' worker; elif /usr/bin/pgrep -f '^${runner_root}/bin/Runner.Listener run' >/dev/null; then printf '%s\\n' listener; else printf '%s\\n' absent; fi" 2>/dev/null) || {
    print unreachable
    return 0
  }
  print -r -- "$state"
}

stop_idle_listener() {
  local vm_ip="$1" state
  state=$(/usr/bin/ssh \
    -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$ssh_key" \
    "admin@${vm_ip}" \
    "if /usr/bin/pgrep -f '^${runner_root}/bin/Runner.Worker ' >/dev/null; then printf '%s\\n' worker; else listener_pid=\$(/usr/bin/pgrep -f '^${runner_root}/bin/Runner.Listener run' | /usr/bin/head -n 1); if [[ -n \"\$listener_pid\" ]]; then /bin/kill -TERM \"\$listener_pid\"; printf '%s\\n' draining; else printf '%s\\n' absent; fi; fi" 2>/dev/null) || {
    print unreachable
    return 0
  }
  print -r -- "$state"
}

wait_for_runner_shutdown() {
  local vm_ip="$1" missing_count=0 deadline state
  deadline=$(( $(/bin/date +%s) + 3300 ))
  while (( missing_count < 3 && $(/bin/date +%s) < deadline )); do
    state=$(runner_process_state "$vm_ip")
    case "$state" in
      worker|listener) missing_count=0 ;;
      absent) (( missing_count += 1 )) ;;
      unreachable) log "runner probe could not reach ${vm_ip}; preserving execution" ;;
    esac
    (( missing_count >= 3 )) || /bin/sleep 5
  done
  if (( missing_count < 3 )); then
    log "runner processes exceeded the 55-minute execution budget"
    return 1
  fi
}

delete_runner_registration() {
  local repository="$1" runner_name="$2" id
  id=$(runner_id "$repository" "$runner_name") || return 0
  [[ -n "$id" ]] || return 0
  github_api DELETE "repos/${repository}/actions/runners/${id}" >/dev/null
}

run_one_ephemeral_runner() {
  local repository="$1" suffix vm_name vm_log vm_pid vm_ip token runner_name runner_status runner_claimed ssh_ready state missing_count cleanup_allowed registration_state lane_lock_owned
  suffix="$(/bin/date -u '+%Y%m%d%H%M%S')-$$"
  vm_name="trips-linux-runner-job-${suffix}"
  runner_name="${runner_name_prefix}-${suffix}"
  vm_log="${log_directory}/${vm_name}.log"
  vm_pid=""
  runner_status=1
  cleanup_allowed=true
  lane_lock_owned=false

  while ! acquire_lane_lock; do
    log "waiting because another Tart job VM is active"
    /bin/sleep 15
  done
  lane_lock_owned=true

  log "cloning ${base_vm} to ${vm_name} for ${repository}"
  /opt/homebrew/bin/tart clone "$base_vm" "$vm_name" || {
    release_lane_lock
    lane_lock_owned=false
    return 1
  }

  cleanup_vm() {
    if [[ "$cleanup_allowed" != true ]]; then
      log "preserving ${vm_name} because safe shutdown was not proven"
      return 0
    fi
    log "deleting ${vm_name}"
    delete_vm "$vm_name" || return 1
    [[ "$lane_lock_owned" != true ]] || release_lane_lock
    lane_lock_owned=false
  }
  trap 'cleanup_vm; exit 0' INT TERM

  {
    /opt/homebrew/bin/tart set "$vm_name" --random-mac || return 1

    log "starting ${vm_name}"
    /opt/homebrew/bin/tart run --no-graphics --no-audio --no-clipboard --net-softnet \
      "$vm_name" >"$vm_log" 2>&1 &
    vm_pid=$!
    vm_ip=$(/opt/homebrew/bin/tart ip "$vm_name" --wait 180) || return 1
    ssh_ready=false
    for _ in {1..60}; do
      if /usr/bin/ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$ssh_key" \
        "admin@${vm_ip}" true 2>/dev/null; then
        ssh_ready=true
        break
      fi
      /bin/sleep 2
    done
    [[ "$ssh_ready" == true ]] || return 1
    log "${vm_name} booted"

    token=$(registration_token "$repository") || return 1
    log "registering ${runner_name} for ${repository}"
    printf '%s\n' "$token" | /usr/bin/ssh \
      -o BatchMode=yes \
      -o ConnectTimeout=30 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=4 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -i "$ssh_key" \
      "admin@${vm_ip}" \
      "IFS= read -r registration_token; cd '$runner_root'; ./config.sh --unattended --ephemeral --disableupdate --url 'https://github.com/${repository}' --token \"\$registration_token\" --name '$runner_name' --labels '$runner_labels' --work _work; /usr/bin/nohup ./run.sh > runner-controller.log 2>&1 < /dev/null &" || {
        cleanup_allowed=false
        return 1
      }
    runner_claimed=false
    for _ in {1..150}; do
      state=$(runner_process_state "$vm_ip")
      if [[ "$state" == worker ]]; then
        runner_claimed=true
        if wait_for_runner_shutdown "$vm_ip"; then
          runner_status=0
        else
          runner_status=1
        fi
        break
      fi
      /bin/sleep 2
    done
    if [[ "$runner_claimed" == false ]]; then
      state=$(stop_idle_listener "$vm_ip")
      missing_count=0
      for _ in {1..24}; do
        state=$(runner_process_state "$vm_ip")
        if [[ "$state" == worker ]]; then
          runner_claimed=true
          break
        elif [[ "$state" == absent ]]; then
          (( missing_count += 1 ))
          (( missing_count >= 6 )) && break
        elif [[ "$state" == listener ]]; then
          stop_idle_listener "$vm_ip" >/dev/null
          missing_count=0
        else
          missing_count=0
        fi
        /bin/sleep 5
      done
      if [[ "$runner_claimed" == true ]]; then
        wait_for_runner_shutdown "$vm_ip" && runner_status=0 || runner_status=1
      elif (( missing_count >= 6 )); then
        registration_state=$(runner_registration_state "$repository" "$runner_name")
        if [[ "$registration_state" == busy ]]; then
          runner_claimed=true
          wait_for_runner_shutdown "$vm_ip" && runner_status=0 || runner_status=1
        elif [[ "$registration_state" == idle || "$registration_state" == missing ]]; then
          log "${runner_name} drained without accepting a job; removing it"
          delete_runner_registration "$repository" "$runner_name" || true
          runner_status=0
        else
          log "could not verify ${runner_name} registration state"
          cleanup_allowed=false
          runner_status=1
        fi
      else
        log "could not prove ${runner_name} idle after draining"
        cleanup_allowed=false
        runner_status=1
      fi
    fi
  } always {
    trap - INT TERM
    cleanup_vm || runner_status=1
    [[ -z "$vm_pid" ]] || wait "$vm_pid" >/dev/null 2>&1 || true
  }
  return "$runner_status"
}

main() {
  local repository stale_ip stale_state preserved_stale=false
  umask 077
  if ! acquire_controller_lock; then
    log "another Linux runner controller owns ${lock_directory}"
    return 0
  fi
  trap 'release_controller_lock' EXIT
  if [[ -n "$required_volume" ]] && ! /sbin/mount | /usr/bin/grep -Fq " on ${required_volume} ("; then
    log "required volume ${required_volume} is not mounted"
    return 1
  fi
  if [[ ! -s "$private_key" || ! -s "$ssh_key" ]]; then
    log "required runner credential is missing"
    return 1
  fi
  if ! /opt/homebrew/bin/tart list --source local --quiet | /usr/bin/grep -qx "$base_vm"; then
    log "base VM ${base_vm} is missing"
    return 1
  fi
  if ! printf '%s\n' "$base_memory_mb" | /usr/bin/grep -Eq '^[1-9][0-9]*$'; then
    log "TRIPS_LINUX_TART_BASE_MEMORY_MB must be a positive integer"
    return 1
  fi
  if ! /opt/homebrew/bin/tart set "$base_vm" --memory "$base_memory_mb"; then
    log "failed to set ${base_vm} memory to ${base_memory_mb} MB"
    return 1
  fi
  if ! ensure_installation_token; then
    log "GitHub App authentication is unavailable"
    return 1
  fi
  if ! /opt/homebrew/bin/gh auth token >/dev/null 2>&1; then
    log "GitHub CLI authentication is unavailable for private-repository queue discovery"
    return 1
  fi

  while IFS= read -r stale_vm; do
    if [[ "$stale_vm" == trips-linux-runner-job-* ]]; then
      if stale_ip=$(/opt/homebrew/bin/tart ip "$stale_vm" 2>/dev/null); then
        stale_state=$(runner_process_state "$stale_ip")
        if [[ "$stale_state" != absent ]]; then
          log "preserving ${stale_vm}; live state is ${stale_state}"
          preserved_stale=true
          continue
        fi
      else
        stale_state=$(/opt/homebrew/bin/tart list --source local --format json |
          VM_NAME="$stale_vm" /usr/bin/python3 -c 'import json,os,sys; print(next((vm["State"] for vm in json.load(sys.stdin) if vm["Name"] == os.environ["VM_NAME"]), "unknown"))')
        if [[ "$stale_state" != stopped ]]; then
          log "preserving ${stale_vm}; state is ${stale_state} and no IP was available"
          preserved_stale=true
          continue
        fi
      fi
      log "removing safely stopped stale ephemeral VM ${stale_vm}"
      delete_vm "$stale_vm" || return 1
    fi
  done < <(/opt/homebrew/bin/tart list --source local --quiet)
  [[ "$preserved_stale" == false ]] || return 1

  while true; do
    if ! user_api_has_headroom; then
      log "GitHub user API has less than 1,500 core requests remaining; pausing discovery for 180 seconds"
      /bin/sleep 180
      continue
    fi
    if repository=$(next_repository); then
      if run_one_ephemeral_runner "$repository"; then
        log "ephemeral runner cycle completed for ${repository}"
      else
        log "ephemeral runner cycle failed for ${repository}; retrying in 15 seconds"
        /bin/sleep 15
      fi
    else
      # Server-side status filters avoid losing active runs behind completed runs.
      # A pass costs at most 336 requests, preserving at least 1,164 in reserve.
      /bin/sleep 180
    fi
  done
}

main
