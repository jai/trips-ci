#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly app_id="${TRIPS_TART_GITHUB_APP_ID:-4452026}"
readonly installation_id="${TRIPS_TART_GITHUB_INSTALLATION_ID:-150444191}"
readonly repositories="${TRIPS_LINUX_TART_REPOSITORIES:-jai/trips-api,jai/trips-frontend,jai/trips-email-ingest-worker,jai/trips-infra,jai/trips,jai/trips-ci,jai/trips-fastlane,jai/openclaw-prompts}"
readonly base_vm="${TRIPS_LINUX_TART_BASE_VM:-trips-linux-runner-base}"
readonly max_concurrent_runners="${TRIPS_LINUX_TART_MAX_CONCURRENT_RUNNERS:-2}"
readonly runner_root="/opt/actions-runner"
readonly runner_name_prefix="${TRIPS_LINUX_TART_RUNNER_NAME_PREFIX:-jais-mac-mini-tart-linux}"
readonly runner_labels="jai-ci"
readonly private_key="/Users/jai/.config/trips-tart-runner/github-app-private-key.pem"
readonly ssh_key="/Users/jai/.config/trips-tart-runner/runner-controller-ed25519"
readonly log_directory="/Users/jai/Library/Logs/trips-linux-tart-runner"
readonly reservation_directory="${log_directory}/reservations"
readonly required_volume="${TRIPS_LINUX_TART_REQUIRED_VOLUME:-}"

export TART_HOME="${TART_HOME:-/Users/jai/.tart}"

mkdir -p "$log_directory"

timestamp() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  print -r -- "$(timestamp) $*"
}

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

registration_token() {
  local repository="$1" jwt installation_token
  jwt=$(github_jwt) || return 1
  installation_token=$(
    /usr/bin/curl -fsS -X POST \
      -H "Authorization: Bearer $jwt" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "https://api.github.com/app/installations/${installation_id}/access_tokens" |
      /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
  ) || return 1
  /usr/bin/curl -fsS -X POST \
    -H "Authorization: Bearer $installation_token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners/registration-token" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

queued_jobs() {
  local repository run_status run_id job_id
  for repository in ${(s:,:)repositories}; do
    for run_status in queued in_progress; do
      while IFS= read -r run_id; do
        [[ -n "$run_id" ]] || continue
        while IFS= read -r job_id; do
          [[ -n "$job_id" ]] || continue
          printf '%s\t%s\n' "$repository" "$job_id"
        done < <(
          /opt/homebrew/bin/gh api \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" \
            --jq '.jobs[] | select(.status == "queued") | select((.labels | index("self-hosted")) and (.labels | index("linux")) and (.labels | index("arm64")) and (.labels | index("jai-ci"))) | .id'
        )
      done < <(
        /opt/homebrew/bin/gh api \
          -H 'Accept: application/vnd.github+json' \
          -H 'X-GitHub-Api-Version: 2022-11-28' \
          "repos/${repository}/actions/runs?status=${run_status}&per_page=20" \
          --jq '.workflow_runs[].id'
      )
    done
  done
}

claim_next_job() {
  local scan_lock claim repository job_id reservation
  scan_lock="${reservation_directory}/.scan-lock"
  /bin/mkdir "$scan_lock" 2>/dev/null || return 1
  claim=""
  {
    while IFS=$'\t' read -r repository job_id; do
      [[ -n "$repository" && -n "$job_id" ]] || continue
      reservation="${reservation_directory}/${repository//\//_}-${job_id}"
      if /bin/mkdir "$reservation" 2>/dev/null; then
        claim="${repository}"$'\t'"${job_id}"
        break
      fi
    done < <(queued_jobs)
  } always {
    /bin/rmdir "$scan_lock" 2>/dev/null || true
  }
  [[ -n "$claim" ]] || return 1
  printf '%s' "$claim"
}

release_job_reservation() {
  local repository="$1" job_id="$2"
  /bin/rmdir "${reservation_directory}/${repository//\//_}-${job_id}" 2>/dev/null || true
}

delete_vm() {
  local vm_name="$1"
  /opt/homebrew/bin/tart stop "$vm_name" >/dev/null 2>&1 || true
  /opt/homebrew/bin/tart delete "$vm_name" >/dev/null 2>&1 || true
}

runner_id() {
  local repository="$1" runner_name="$2"
  /opt/homebrew/bin/gh api \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "repos/${repository}/actions/runners?per_page=100" \
    --jq ".runners[] | select(.name == \"${runner_name}\") | .id"
}

runner_is_busy() {
  local repository="$1" runner_name="$2"
  /opt/homebrew/bin/gh api \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "repos/${repository}/actions/runners?per_page=100" \
    --jq ".runners[] | select(.name == \"${runner_name}\") | .busy" |
    /usr/bin/grep -qx 'true'
}

delete_runner_registration() {
  local repository="$1" runner_name="$2" id
  id=$(runner_id "$repository" "$runner_name") || return 0
  [[ -n "$id" ]] || return 0
  /opt/homebrew/bin/gh api --method DELETE \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "repos/${repository}/actions/runners/${id}" >/dev/null
}

run_one_ephemeral_runner() {
  local repository="$1" job_id="$2" suffix vm_name vm_log vm_pid vm_ip token runner_name runner_status runner_pid runner_claimed ssh_ready
  suffix="$(/bin/date -u '+%Y%m%d%H%M%S')-${job_id}-$$"
  vm_name="trips-linux-runner-job-${suffix}"
  runner_name="${runner_name_prefix}-${suffix}"
  vm_log="${log_directory}/${vm_name}.log"
  vm_pid=""
  runner_pid=""
  runner_status=1

  log "cloning ${base_vm} to ${vm_name} for ${repository}"
  /opt/homebrew/bin/tart clone "$base_vm" "$vm_name" || return 1

  cleanup_vm() {
    log "deleting ${vm_name}"
    delete_vm "$vm_name"
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
      "IFS= read -r registration_token; cd '$runner_root'; ./config.sh --unattended --ephemeral --disableupdate --url 'https://github.com/${repository}' --token \"\$registration_token\" --name '$runner_name' --labels '$runner_labels' --work _work; exec ./run.sh" &
    runner_pid=$!
    runner_claimed=false
    for _ in {1..150}; do
      if ! /bin/kill -0 "$runner_pid" 2>/dev/null; then
        wait "$runner_pid"
        runner_status=$?
        runner_claimed=true
        break
      fi
      if runner_is_busy "$repository" "$runner_name"; then
        runner_claimed=true
        wait "$runner_pid"
        runner_status=$?
        break
      fi
      /bin/sleep 2
    done
    if [[ "$runner_claimed" == false ]]; then
      log "${runner_name} remained idle; removing it"
      /bin/kill "$runner_pid" 2>/dev/null || true
      wait "$runner_pid" >/dev/null 2>&1 || true
      delete_runner_registration "$repository" "$runner_name" || true
      runner_status=0
    fi
  } always {
    trap - INT TERM
    cleanup_vm
    [[ -z "$vm_pid" ]] || wait "$vm_pid" >/dev/null 2>&1 || true
  }
  return "$runner_status"
}

worker_loop() {
  local worker_index="$1" claim repository job_id
  while true; do
    if claim=$(claim_next_job); then
      IFS=$'\t' read -r repository job_id <<< "$claim"
      log "worker ${worker_index} reserved queued job ${job_id} for ${repository}"
      {
        if run_one_ephemeral_runner "$repository" "$job_id"; then
          log "worker ${worker_index} completed a job for ${repository}"
        else
          log "worker ${worker_index} runner cycle failed for ${repository}; retrying in 15 seconds"
          /bin/sleep 15
        fi
      } always {
        release_job_reservation "$repository" "$job_id"
      }
    else
      /bin/sleep 2
    fi
  done
}

main() {
  local stale_reservation stale_vm worker_index
  local -a worker_pids
  umask 077
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
  if ! /opt/homebrew/bin/gh auth status >/dev/null 2>&1; then
    log "GitHub CLI authentication is unavailable"
    return 1
  fi
  if ! printf '%s\n' "$max_concurrent_runners" | /usr/bin/grep -Eq '^[1-9][0-9]*$'; then
    log "TRIPS_LINUX_TART_MAX_CONCURRENT_RUNNERS must be a positive integer"
    return 1
  fi

  /bin/mkdir -p "$reservation_directory"
  /bin/rmdir "${reservation_directory}/.scan-lock" 2>/dev/null || true
  for stale_reservation in "${reservation_directory}"/*(N/); do
    /bin/rmdir "$stale_reservation" 2>/dev/null || true
  done

  while IFS= read -r stale_vm; do
    if [[ "$stale_vm" == trips-linux-runner-job-* ]]; then
      log "removing stale ephemeral VM ${stale_vm}"
      delete_vm "$stale_vm"
    fi
  done < <(/opt/homebrew/bin/tart list --source local --quiet)

  worker_pids=()
  for (( worker_index = 1; worker_index <= max_concurrent_runners; worker_index++ )); do
    worker_loop "$worker_index" &
    worker_pids+=("$!")
  done
  trap '/bin/kill ${worker_pids[@]} 2>/dev/null || true; wait; exit 0' INT TERM
  log "started ${max_concurrent_runners} concurrent Linux runner workers"
  wait
}

main
