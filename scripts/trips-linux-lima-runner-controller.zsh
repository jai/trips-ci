#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly app_id="${TRIPS_TART_GITHUB_APP_ID:-4452026}"
readonly installation_id="${TRIPS_TART_GITHUB_INSTALLATION_ID:-150444191}"
readonly repositories="${TRIPS_LINUX_LIMA_REPOSITORIES:-jai/trips-api,jai/trips-frontend,jai/trips-email-ingest-worker,jai/trips-infra,jai/trips,jai/trips-ci,jai/trips-fastlane,jai/openclaw-prompts,jai/tonegate}"
readonly base_vm="${TRIPS_LINUX_LIMA_BASE_VM:-trips-linux-runner-base}"
readonly slot="${TRIPS_LINUX_LIMA_SLOT:?TRIPS_LINUX_LIMA_SLOT must be a or b}"
readonly cpus="${TRIPS_LINUX_LIMA_CPUS:-3}"
readonly memory_gib="${TRIPS_LINUX_LIMA_MEMORY_GIB:-8}"
readonly runner_root="/opt/actions-runner"
readonly runner_name_prefix="${TRIPS_LINUX_LIMA_RUNNER_NAME_PREFIX:-borg-cube-03-lima-${slot}}"
readonly runner_labels="jai-ci"
readonly private_key="/Users/jai/.config/trips-tart-runner/github-app-private-key.pem"
readonly log_directory="/Users/jai/Library/Logs/trips-linux-lima-runner"
readonly selection_lock="${LIMA_HOME:-/Users/jai/.lima}/.trips-linux-runner-selection-lock"

export LIMA_HOME="${LIMA_HOME:-/Users/jai/.lima}"
mkdir -p "$log_directory"

timestamp() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  print -r -- "$(timestamp) slot=${slot} $*"
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

installation_token() {
  local jwt
  jwt=$(github_jwt) || return 1
  /usr/bin/curl -fsS -X POST \
    -H "Authorization: Bearer $jwt" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/app/installations/${installation_id}/access_tokens" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

registration_token() {
  local repository="$1" token
  token=$(installation_token) || return 1
  /usr/bin/curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners/registration-token" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

repository_is_private() {
  local repository="$1" token
  token=$(installation_token) || return 1
  /usr/bin/curl -fsS \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}" |
    /usr/bin/python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("private") is True else 1)'
}

runner_id() {
  local repository="$1" runner_name="$2" token
  token=$(installation_token) || return 1
  /usr/bin/curl -fsS \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners?per_page=100" |
    /usr/bin/python3 -c 'import json,sys; name=sys.argv[1]; print(next((str(r["id"]) for r in json.load(sys.stdin)["runners"] if r["name"] == name), ""))' "$runner_name"
}

runner_is_busy() {
  local repository="$1" runner_name="$2" token
  token=$(installation_token) || return 1
  /usr/bin/curl -fsS \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners?per_page=100" |
    /usr/bin/python3 -c 'import json,sys; name=sys.argv[1]; raise SystemExit(0 if any(r["name"] == name and r["busy"] for r in json.load(sys.stdin)["runners"]) else 1)' "$runner_name"
}

delete_runner_registration() {
  local repository="$1" runner_name="$2" id token
  id=$(runner_id "$repository" "$runner_name") || return 0
  [[ -n "$id" ]] || return 0
  token=$(installation_token) || return 1
  /usr/bin/curl -fsS -X DELETE \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners/${id}" >/dev/null
}

repository_has_queued_job() {
  local repository="$1" run_status run_id head_repository
  for run_status in queued in_progress; do
    while IFS=$'\t' read -r run_id head_repository; do
      [[ -n "$run_id" ]] || continue
      [[ "$head_repository" == "$repository" ]] || continue
      if /opt/homebrew/bin/gh api \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" |
        /usr/bin/python3 -c 'import json,sys
required={"self-hosted","linux","arm64","jai-ci"}
jobs=json.load(sys.stdin).get("jobs",[])
print(sum(1 for job in jobs if job.get("status") == "queued" and {str(label).lower() for label in job.get("labels",[])} == required))' |
        /usr/bin/grep -qxv '0'; then
        return 0
      fi
    done < <(
      /opt/homebrew/bin/gh api \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        --paginate \
        "repos/${repository}/actions/runs?status=${run_status}&per_page=100" \
        --jq '.workflow_runs[] | [.id, .head_repository.full_name] | @tsv'
    )
  done
  return 1
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
  local vm_name="$1"
  /opt/homebrew/bin/limactl stop --force "$vm_name" >/dev/null 2>&1 || true
  /opt/homebrew/bin/limactl delete --force "$vm_name" >/dev/null 2>&1 || true
}

run_one_ephemeral_runner() {
  local repository="$1" suffix vm_name token runner_name runner_pid runner_status runner_claimed
  suffix="$(/bin/date -u '+%Y%m%d%H%M%S')-$$"
  vm_name="trips-linux-runner-${slot}-job-${suffix}"
  runner_name="${runner_name_prefix}-${suffix}"
  runner_pid=""
  runner_status=1

  log "cloning ${base_vm} to ${vm_name} for ${repository}"
  /opt/homebrew/bin/limactl clone "$base_vm" "$vm_name" \
    --cpus="$cpus" --memory="$memory_gib" --mount-none --start --tty=false || return 1

  cleanup() {
    delete_runner_registration "$repository" "$runner_name" || true
    log "deleting ${vm_name}"
    delete_vm "$vm_name"
  }
  trap 'release_selection_lock; cleanup; exit 0' INT TERM

  {
    /opt/homebrew/bin/limactl shell "$vm_name" -- \
      bash -lc 'set -e; test "$(nproc)" = 3; test "$(free -g | awk '\''/^Mem:/{print $2}'\'')" -ge 7; docker info >/dev/null; docker compose version; test -x /opt/actions-runner/bin/Runner.Listener' || return 1

    token=$(registration_token "$repository") || return 1
    log "registering ${runner_name} for ${repository}"
    printf '%s\n' "$token" | /opt/homebrew/bin/limactl shell "$vm_name" -- \
      bash -lc "IFS= read -r registration_token; cd '$runner_root'; ./config.sh --unattended --ephemeral --disableupdate --url 'https://github.com/${repository}' --token \"\$registration_token\" --name '$runner_name' --labels '$runner_labels' --work _work; exec ./run.sh" &
    runner_pid=$!
    runner_claimed=false
    for _ in {1..150}; do
      if ! /bin/kill -0 "$runner_pid" 2>/dev/null; then
        wait "$runner_pid"
        runner_status=$?
        break
      fi
      if runner_is_busy "$repository" "$runner_name"; then
        runner_claimed=true
        log "${runner_name} claimed a job"
        release_selection_lock
        wait "$runner_pid"
        runner_status=$?
        break
      fi
      /bin/sleep 2
    done
    if [[ "$runner_claimed" == false ]] && /bin/kill -0 "$runner_pid" 2>/dev/null; then
      log "${runner_name} remained idle; removing it"
      /bin/kill "$runner_pid" 2>/dev/null || true
      wait "$runner_pid" >/dev/null 2>&1 || true
      runner_status=0
    fi
  } always {
    release_selection_lock
    trap - INT TERM
    cleanup
  }
  return "$runner_status"
}

main() {
  local repository
  umask 077
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
  if ! /opt/homebrew/bin/limactl list "$base_vm" --json 2>/dev/null |
    /usr/bin/grep -q '"status":"Stopped"'; then
    log "stopped Lima base ${base_vm} is missing"
    return 1
  fi
  if ! /opt/homebrew/bin/gh auth status >/dev/null 2>&1; then
    log "GitHub CLI authentication is unavailable"
    return 1
  fi
  for repository in ${(s:,:)repositories}; do
    if ! repository_is_private "$repository"; then
      log "refusing non-private or unavailable repository ${repository}"
      return 1
    fi
  done

  while IFS= read -r stale_vm; do
    [[ "$stale_vm" == trips-linux-runner-${slot}-job-* ]] || continue
    log "removing stale ephemeral VM ${stale_vm}"
    delete_vm "$stale_vm"
  done < <(
    /opt/homebrew/bin/limactl list --json 2>/dev/null |
      /usr/bin/python3 -c 'import json,sys; [print(json.loads(line)["name"]) for line in sys.stdin if line.strip()]'
  )

  while true; do
    acquire_selection_lock
    if repository=$(next_repository); then
      if run_one_ephemeral_runner "$repository"; then
        log "ephemeral runner completed a job for ${repository}"
      else
        log "ephemeral runner cycle failed for ${repository}; retrying in 15 seconds"
        /bin/sleep 15
      fi
    else
      # Keep the shared lock while idle so the second slot cannot duplicate the
      # repository scan and exhaust the authenticated GitHub API quota.
      /bin/sleep 30
      release_selection_lock
    fi
  done
}

main
