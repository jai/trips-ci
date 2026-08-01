#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly app_id="4452026"
readonly installation_id="150444191"
readonly repository="jai/trips-frontend"
readonly base_vm="trips-runner-base"
readonly runner_root="/Users/admin/actions-runner"
readonly runner_labels="borg-cube-03,tart,ios"
readonly private_key="/Users/jai/.config/trips-tart-runner/github-app-private-key.pem"
readonly ssh_key="/Users/jai/.config/trips-tart-runner/runner-controller-ed25519"
readonly log_directory="/Users/jai/Library/Logs/trips-tart-runner"
readonly work_disk_directory="/Users/jai/.local/share/trips-tart-runner/work-disks"

mkdir -p "$log_directory" "$work_disk_directory"

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
  local jwt installation_token
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

delete_vm() {
  local vm_name="$1"
  /opt/homebrew/bin/tart stop "$vm_name" >/dev/null 2>&1 || true
  /opt/homebrew/bin/tart delete "$vm_name" >/dev/null 2>&1 || true
}

run_one_ephemeral_runner() {
  local suffix vm_name vm_log vm_pid vm_ip token runner_name runner_status work_disk ssh_ready
  suffix="$(/bin/date -u '+%Y%m%d%H%M%S')-$$"
  vm_name="trips-runner-job-${suffix}"
  runner_name="borg-cube-03-${suffix}"
  vm_log="${log_directory}/${vm_name}.log"
  work_disk="${work_disk_directory}/${vm_name}.raw"
  vm_pid=""
  runner_status=1

  log "cloning ${base_vm} to ${vm_name}"
  /opt/homebrew/bin/tart clone "$base_vm" "$vm_name" || return 1

  cleanup_vm() {
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
      'set -e; root_store=$(diskutil info / | awk -F: '\''/APFS Physical Store/{gsub(/ /, "", $2); print $2; exit}'\''); root_device=$(printf "%s" "$root_store" | sed -E "s/s[0-9]+$//"); work_device=$(diskutil list physical | awk '\''/^\/dev\/disk[0-9]+ /{gsub("/dev/", "", $1); print $1}'\'' | grep -v "^${root_device}$"); test "$(printf "%s\n" "$work_device" | wc -l | tr -d " ")" = 1; printf "%s\n" "$root_device" "$work_device" | while IFS= read -r device; do printf "%s\n" "$device" | grep -Eq "^disk[0-9]+$" || exit 1; done; xcrun simctl runtime scan-and-mount >/dev/null; runtime_ready=false; for _ in {1..45}; do if xcrun simctl list runtimes | grep -q "iOS"; then runtime_ready=true; break; fi; sleep 2; done; [ "$runtime_ready" = true ]; sudo diskutil eraseDisk APFS RunnerWork GPT "/dev/$work_device" >/dev/null; mkdir -p /Volumes/RunnerWork/_work /Volumes/RunnerWork/DerivedData /Volumes/RunnerWork/Archives /Volumes/RunnerWork/tmp /Volumes/RunnerWork/npm-cache /Volumes/RunnerWork/user-cache /Users/admin/Library/Developer/Xcode; rm -rf /Users/admin/Library/Developer/Xcode/DerivedData /Users/admin/Library/Developer/Xcode/Archives; sudo rm -rf /Users/admin/Library/Caches; ln -s /Volumes/RunnerWork/DerivedData /Users/admin/Library/Developer/Xcode/DerivedData; ln -s /Volumes/RunnerWork/Archives /Users/admin/Library/Developer/Xcode/Archives; ln -s /Volumes/RunnerWork/user-cache /Users/admin/Library/Caches' || return 1

    token=$(registration_token) || return 1
    log "registering ${runner_name}"
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
  umask 077
  if [[ ! -s "$private_key" || ! -s "$ssh_key" ]]; then
    log "required runner credential is missing"
    return 1
  fi
  if ! /opt/homebrew/bin/tart list --source local --quiet | /usr/bin/grep -qx "${base_vm}"; then
    log "base VM ${base_vm} is missing"
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
    if run_one_ephemeral_runner; then
      log "ephemeral runner completed a job"
    else
      log "ephemeral runner cycle failed; retrying in 30 seconds"
      /bin/sleep 30
    fi
  done
}

main
