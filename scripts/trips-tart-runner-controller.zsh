#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly app_id="${TRIPS_TART_GITHUB_APP_ID:-4452026}"
readonly installation_id="${TRIPS_TART_GITHUB_INSTALLATION_ID:-150444191}"
readonly repositories="${TRIPS_TART_REPOSITORIES:-jai/trips-frontend,jai/tonegate}"
readonly base_vm="${TRIPS_TART_BASE_VM:-trips-runner-base}"
readonly base_cpus="${TRIPS_TART_BASE_CPUS:-4}"
readonly base_memory_mb="${TRIPS_TART_BASE_MEMORY_MB:-16384}"
readonly runner_root="/Users/admin/actions-runner"
readonly runner_host_label="${TRIPS_TART_RUNNER_HOST_LABEL:-borg-cube-03}"
readonly runner_name_prefix="${TRIPS_TART_RUNNER_NAME_PREFIX:-${runner_host_label}}"
readonly runner_labels="${runner_host_label},tart,ios"
readonly private_key="/Users/jai/.config/trips-tart-runner/github-app-private-key.pem"
readonly ssh_key="/Users/jai/.config/trips-tart-runner/runner-controller-ed25519"
readonly log_directory="/Users/jai/Library/Logs/trips-tart-runner"
readonly work_disk_directory="${TRIPS_TART_WORK_DISK_DIRECTORY:-/Users/jai/.local/share/trips-tart-runner/work-disks}"
readonly minimum_root_free_gib="${TRIPS_TART_MINIMUM_ROOT_FREE_GIB:-1}"
readonly required_volume="${TRIPS_TART_REQUIRED_VOLUME:-}"
readonly gh_cli="${TRIPS_TART_GH_CLI:-/opt/homebrew/bin/gh}"

export TART_HOME="${TART_HOME:-/Users/jai/.tart}"

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

repository_has_queued_job() {
  local repository="$1" run_status run_id head_repository
  for run_status in queued in_progress; do
    while IFS=$'\t' read -r run_id head_repository; do
      [[ -n "$run_id" ]] || continue
      [[ "$head_repository" == "$repository" ]] || continue
      if "$gh_cli" api \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" \
        --jq '[.jobs[] | select(.status == "queued") | select((.labels | index("self-hosted")) and (.labels | index("macOS")) and (.labels | index("ARM64")) and (.labels | index("tart")) and (.labels | index("ios")))] | length' |
        /usr/bin/grep -qxv '0'; then
        return 0
      fi
    done < <(
      "$gh_cli" api \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "repos/${repository}/actions/runs?status=${run_status}&per_page=20" \
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

delete_vm() {
  local vm_name="$1"
  /opt/homebrew/bin/tart stop "$vm_name" >/dev/null 2>&1 || true
  /opt/homebrew/bin/tart delete "$vm_name" >/dev/null 2>&1 || true
}

run_one_ephemeral_runner() {
  local repository="$1" suffix vm_name vm_log vm_pid vm_ip token runner_name runner_status work_disk ssh_ready linux_runner_count
  suffix="$(/bin/date -u '+%Y%m%d%H%M%S')-$$"
  vm_name="trips-runner-job-${suffix}"
  runner_name="${runner_name_prefix}-${suffix}"
  vm_log="${log_directory}/${vm_name}.log"
  work_disk="${work_disk_directory}/${vm_name}.raw"
  vm_pid=""
  runner_status=1

  while true; do
    linux_runner_count=$(
      /opt/homebrew/bin/limactl list --json 2>/dev/null |
        /usr/bin/python3 -c 'import json,sys; [print(json.loads(line)["name"]) for line in sys.stdin if line.strip()]' |
        /usr/bin/grep -c '^trips-linux-runner-[ab]-job-' || true
    )
    (( linux_runner_count <= 2 )) && break
    log "waiting for Linux runner count to return to the two-slot contract"
    /bin/sleep 15
  done

  log "cloning ${base_vm} to ${vm_name}"
  /opt/homebrew/bin/tart clone "$base_vm" "$vm_name" || return 1

  cleanup_vm() {
    delete_runner_registration "$repository" "$runner_name" || true
    log "deleting ${vm_name}"
    delete_vm "$vm_name"
    /bin/rm -f "$work_disk"
  }
  trap 'cleanup_vm; exit 0' INT TERM

  {
    /opt/homebrew/bin/tart set "$vm_name" --random-mac --random-serial || return 1
    /usr/sbin/mkfile -n 60g "$work_disk" || return 1

    log "starting ${vm_name}"
    /opt/homebrew/bin/tart run --no-graphics --no-audio --no-clipboard \
      --disk="${work_disk}:sync=none" "$vm_name" >"$vm_log" 2>&1 &
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

    /usr/bin/ssh \
      -o BatchMode=yes \
      -o ConnectTimeout=30 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -i "$ssh_key" \
      "admin@${vm_ip}" \
      "set -e; xcodebuild -version >/dev/null; java -version >/dev/null 2>&1; test -x /Users/admin/actions-runner/bin/Runner.Listener; test \"\$(df -g / | awk 'NR == 2 {print \$4}')\" -ge '${minimum_root_free_gib}'; root_store=\$(diskutil info / | awk -F: '/APFS Physical Store/{gsub(/ /, \"\", \$2); print \$2; exit}'); root_device=\$(printf \"%s\" \"\$root_store\" | sed -E \"s/s[0-9]+\$//\"); work_device=\$(diskutil list physical | awk '/^\\/dev\\/disk[0-9]+ /{gsub(\"/dev/\", \"\", \$1); print \$1}' | grep -v \"^\${root_device}\$\"); test \"\$(printf \"%s\\n\" \"\$work_device\" | wc -l | tr -d \" \")\" = 1; printf \"%s\\n\" \"\$root_device\" \"\$work_device\" | while IFS= read -r device; do printf \"%s\\n\" \"\$device\" | grep -Eq \"^disk[0-9]+\$\" || exit 1; done; sudo diskutil eraseDisk APFS RunnerWork GPT \"/dev/\$work_device\" >/dev/null; mkdir -p /Volumes/RunnerWork/_work /Volumes/RunnerWork/DerivedData /Volumes/RunnerWork/Archives /Volumes/RunnerWork/tmp /Volumes/RunnerWork/npm-cache /Volumes/RunnerWork/user-cache /Volumes/RunnerWork/core-simulator-cache /Volumes/RunnerWork/core-simulator-devices /Volumes/RunnerWork/expo /Volumes/RunnerWork/gradle /Volumes/RunnerWork/cocoapods /Volumes/RunnerWork/runner-diag /Users/admin/Library/Developer/Xcode /Users/admin/Library/Developer/CoreSimulator; sudo rm -rf /Library/Developer/CoreSimulator/Caches; sudo ln -s /Volumes/RunnerWork/core-simulator-cache /Library/Developer/CoreSimulator/Caches; xcrun simctl runtime scan-and-mount >/dev/null; runtime_ready=false; for _ in {1..45}; do if xcrun simctl list runtimes | grep -q \"iOS\"; then runtime_ready=true; break; fi; sleep 2; done; [ \"\$runtime_ready\" = true ]; launchctl kill SIGKILL \"gui/\$(id -u)/com.apple.CoreSimulator.CoreSimulatorService\" >/dev/null 2>&1 || true; sleep 2; sudo rm -rf /Users/admin/Library/Caches || true; sudo rm -rf /Users/admin/Library/Developer/Xcode/DerivedData /Users/admin/Library/Developer/Xcode/Archives /Users/admin/Library/Developer/CoreSimulator/Devices /Users/admin/.expo /Users/admin/.gradle /Users/admin/.cocoapods /Users/admin/actions-runner/_diag; ln -s /Volumes/RunnerWork/DerivedData /Users/admin/Library/Developer/Xcode/DerivedData; ln -s /Volumes/RunnerWork/Archives /Users/admin/Library/Developer/Xcode/Archives; ln -s /Volumes/RunnerWork/core-simulator-devices /Users/admin/Library/Developer/CoreSimulator/Devices; if [ ! -e /Users/admin/Library/Caches ]; then ln -s /Volumes/RunnerWork/user-cache /Users/admin/Library/Caches; fi; ln -s /Volumes/RunnerWork/expo /Users/admin/.expo; ln -s /Volumes/RunnerWork/gradle /Users/admin/.gradle; ln -s /Volumes/RunnerWork/cocoapods /Users/admin/.cocoapods; ln -s /Volumes/RunnerWork/runner-diag /Users/admin/actions-runner/_diag" || return 1

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
      "IFS= read -r registration_token; export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/Volumes/RunnerWork/tmp npm_config_cache=/Volumes/RunnerWork/npm-cache; cd '$runner_root'; ./config.sh --unattended --ephemeral --disableupdate --url 'https://github.com/${repository}' --token \"\$registration_token\" --name '$runner_name' --labels '$runner_labels' --work /Volumes/RunnerWork/_work; ./run.sh"
    runner_status=$?
  } always {
    trap - INT TERM
    cleanup_vm
    [[ -z "$vm_pid" ]] || wait "$vm_pid" >/dev/null 2>&1 || true
  }
  return "$runner_status"
}

main() {
  local repository
  umask 077
  mkdir -p "$log_directory"
  if [[ -n "$required_volume" ]] && ! /sbin/mount | /usr/bin/grep -Fq " on ${required_volume} ("; then
    log "required volume ${required_volume} is not mounted"
    return 1
  fi
  mkdir -p "$work_disk_directory"
  if [[ ! -s "$private_key" || ! -s "$ssh_key" ]]; then
    log "required runner credential is missing"
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
  if ! /opt/homebrew/bin/tart list --source local --quiet | /usr/bin/grep -qx "${base_vm}"; then
    log "base VM ${base_vm} is missing"
    return 1
  fi
  if [[ "$base_cpus" != 4 || "$base_memory_mb" != 16384 ]]; then
    log "resource contract requires 4 CPUs and 16384 MB for iOS"
    return 1
  fi
  if ! /opt/homebrew/bin/tart set "$base_vm" --cpu "$base_cpus" --memory "$base_memory_mb"; then
    log "failed to apply the iOS base resource contract"
    return 1
  fi

  while IFS= read -r stale_vm; do
    if [[ "$stale_vm" == trips-runner-job-* ]]; then
      log "removing stale ephemeral VM ${stale_vm}"
      delete_vm "$stale_vm"
    fi
  done < <(/opt/homebrew/bin/tart list --source local --quiet)
  for stale_disk in "${work_disk_directory}"/trips-runner-job-*.raw(N); do
    log "removing stale ephemeral work disk ${stale_disk:t}"
    /bin/rm -f "$stale_disk"
  done

  while true; do
    if repository=$(next_repository); then
      if run_one_ephemeral_runner "$repository"; then
        log "ephemeral runner completed a job for ${repository}"
      else
        log "ephemeral runner cycle failed for ${repository}; retrying in 30 seconds"
        /bin/sleep 30
      fi
    else
      /bin/sleep 30
    fi
  done
}

if [[ "${TRIPS_RUNNER_CONTROLLER_LIBRARY_ONLY:-false}" != true ]]; then
  main
fi
