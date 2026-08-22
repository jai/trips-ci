#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly app_id="${TRIPS_TART_GITHUB_APP_ID:-4452026}"
readonly installation_id="${TRIPS_TART_GITHUB_INSTALLATION_ID:-150444191}"
readonly repository="${TRIPS_TART_REPOSITORY:-jai/trips-frontend}"
readonly base_vm="${TRIPS_TART_BASE_VM:-trips-runner-base}"
readonly runner_root="/Users/admin/actions-runner"
readonly runner_host_label="${TRIPS_TART_RUNNER_HOST_LABEL:-borg-cube-03}"
readonly runner_name_prefix="${TRIPS_TART_RUNNER_NAME_PREFIX:-${runner_host_label}}"
readonly runner_labels="${runner_host_label},tart,ios"
readonly private_key="/Users/jai/.config/trips-tart-runner/github-app-private-key.pem"
readonly ssh_key="/Users/jai/.config/trips-tart-runner/runner-controller-ed25519"
readonly log_directory="/Users/jai/Library/Logs/trips-tart-runner"
readonly work_disk_directory="${TRIPS_TART_WORK_DISK_DIRECTORY:-/Users/jai/.local/share/trips-tart-runner/work-disks}"
readonly required_volume="${TRIPS_TART_REQUIRED_VOLUME:-}"
readonly lock_directory="${log_directory}/controller.lock"
readonly lane_lock_directory="/Users/jai/Library/Logs/trips-tart-runner-lane.lock"
readonly native_priority_file="${TRIPS_TART_NATIVE_PRIORITY_FILE:-/Users/jai/Library/Logs/trips-tart-runner-native-priority}"
readonly native_priority_lock="${native_priority_file}.lock"

typeset -g github_installation_token=""
typeset -g github_installation_token_expires_at=0

export TART_HOME="${TART_HOME:-/Users/jai/.tart}"

if [[ "${TRIPS_RUNNER_CONTROLLER_TEST_MODE:-false}" != true ]]; then
  mkdir -p "$log_directory"
fi

timestamp() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  print -r -- "$(timestamp) $*"
}

acquire_lock() {
  /usr/bin/shlock -f "$1" -p $$
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
acquire_priority_lock() { acquire_lock "$native_priority_lock"; }
release_priority_lock() { release_lock "$native_priority_lock"; }

shared_lane_has_ephemeral_vm() {
  local vm_list
  vm_list=$(/opt/homebrew/bin/tart list --source local --quiet) || return 0
  printf '%s\n' "$vm_list" | /usr/bin/grep -Eq '^trips-(linux-)?runner-job-'
}

clone_artifact_result() {
  local vm_name="$1" list_status="$2" vm_list="$3"
  (( list_status == 0 )) || return 3
  if printf '%s\n' "$vm_list" | /usr/bin/grep -qx "$vm_name"; then
    log "clone failed after creating ${vm_name}; exiting for startup reconciliation"
    return 3
  fi
  return 1
}

failed_clone_result() {
  local vm_name="$1" vm_list list_status
  vm_list=$(/opt/homebrew/bin/tart list --source local --quiet)
  list_status=$?
  clone_artifact_result "$vm_name" "$list_status" "$vm_list"
}

acquire_clean_lane_lock() {
  acquire_lane_lock || return 1
  if shared_lane_has_ephemeral_vm; then
    release_lane_lock
    return 1
  fi
}

request_native_lane_priority() {
  local candidate="${native_priority_file}.$$"
  while ! acquire_priority_lock; do /bin/sleep 1; done
  printf '%s\n' $$ >"$candidate"
  /bin/mv -f "$candidate" "$native_priority_file"
  release_priority_lock
}

release_native_lane_priority() {
  local owner_pid=""
  while ! acquire_priority_lock; do /bin/sleep 1; done
  [[ -r "$native_priority_file" ]] && read -r owner_pid <"$native_priority_file"
  [[ "$owner_pid" != $$ ]] || /bin/rm -f "$native_priority_file"
  release_priority_lock
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

ensure_installation_token() {
  local jwt now response
  now=$(/bin/date +%s)
  if [[ -n "$github_installation_token" ]] && (( now < github_installation_token_expires_at )); then return 0; fi
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
  /usr/bin/curl -fsS -X "$method" -H "Authorization: Bearer $github_installation_token" \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/${endpoint}"
}

registration_token() {
  local installation_token="$1"
  /usr/bin/curl -fsS -X POST \
    -H "Authorization: Bearer $installation_token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners/registration-token" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

repository_has_queued_native_job() {
  local page response run_count run_id run_ids="" run_status queued_job_count
  for run_status in queued in_progress; do
    page=1
    while true; do
      response=$(github_api GET "repos/${repository}/actions/runs?status=${run_status}&per_page=100&page=${page}") || return 1
      run_ids+=$(printf '%s' "$response" |
        /usr/bin/python3 -c 'import json,sys; print("\n".join(str(run["id"]) for run in json.load(sys.stdin)["workflow_runs"]))') || return 1
      run_ids+=$'\n'
      run_count=$(printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)["workflow_runs"]))') || return 1
      (( run_count < 100 )) && break
      (( page += 1 ))
    done
  done

  while IFS= read -r run_id; do
    [[ -n "$run_id" ]] || continue
    queued_job_count=$(github_api GET "repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" |
      AVAILABLE_LABELS="self-hosted,macOS,ARM64,${runner_labels}" /usr/bin/python3 -c 'import json,os,sys; available=set(os.environ["AVAILABLE_LABELS"].split(",")); print(sum(job["status"] == "queued" and set(job["labels"]).issubset(available) for job in json.load(sys.stdin)["jobs"]))') || continue
    if [[ "$queued_job_count" == <1-> ]]; then
      return 0
    fi
  done <<<"$run_ids"
  return 1
}

installation_api_has_headroom() {
  local remaining
  remaining=$(github_api GET rate_limit |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["resources"]["core"]["remaining"])') || return 1
  [[ "$remaining" == <1500-> ]]
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
    "if /usr/bin/pgrep -f '^${runner_root}/bin/Runner.Worker ' >/dev/null; then printf '%s\\n' worker; else listener_pid=\$(/usr/bin/pgrep -f '^${runner_root}/bin/Runner.Listener run' | /usr/bin/head -n 1); if [[ -n \"\$listener_pid\" ]]; then /bin/kill -TERM \"\$listener_pid\"; printf '%s\\n' draining; else printf '%s\\n' absent; fi; fi" 2>/dev/null) || {
    print unreachable
    return 0
  }
  print -r -- "$state"
}

reconcile_stale_runner_state() {
  local vm_ip="$1" state="$2"
  if [[ "$state" == listener ]]; then
    state=$(stop_idle_listener "$vm_ip")
    [[ "$state" != draining ]] || /bin/sleep 5
    state=$(runner_process_state "$vm_ip")
  fi
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

supervise_claimed_runner() {
  local vm_ip="$1" state
  wait_for_runner_shutdown "$vm_ip" && return 0
  state=$(runner_process_state "$vm_ip")
  if [[ "$state" != absent ]]; then
    log "preserving claimed runner after supervision ended; live state is ${state}"
    cleanup_allowed=false
  fi
  return 1
}

delete_runner_registration() {
  local runner_name="$1" id
  id=$(github_api GET "repos/${repository}/actions/runners?per_page=100" |
    RUNNER_NAME="$runner_name" /usr/bin/python3 -c 'import json,os,sys; print(next((runner["id"] for runner in json.load(sys.stdin)["runners"] if runner["name"] == os.environ["RUNNER_NAME"]), ""))') || return 0
  [[ -n "$id" ]] || return 0
  github_api DELETE "repos/${repository}/actions/runners/${id}" >/dev/null
}

runner_registration_state() {
  local runner_name="$1"
  github_api GET "repos/${repository}/actions/runners?per_page=100" |
    RUNNER_NAME="$runner_name" /usr/bin/python3 -c 'import json,os,sys; runner=next((r for r in json.load(sys.stdin)["runners"] if r["name"] == os.environ["RUNNER_NAME"]), None); print("missing" if runner is None else ("busy" if runner["busy"] else "idle"))' || print unreachable
}

run_one_ephemeral_runner() {
  local suffix vm_name vm_log vm_pid vm_ip token runner_name runner_status runner_claimed work_disk ssh_ready state missing_count cleanup_allowed registration_state lane_lock_owned lane_priority_requested
  suffix="$(/bin/date -u '+%Y%m%d%H%M%S')-$$"
  vm_name="trips-runner-job-${suffix}"
  runner_name="${runner_name_prefix}-${suffix}"
  vm_log="${log_directory}/${vm_name}.log"
  work_disk="${work_disk_directory}/${vm_name}.raw"
  vm_pid=""
  runner_status=1
  cleanup_allowed=true
  lane_lock_owned=false
  lane_priority_requested=false

  request_native_lane_priority
  lane_priority_requested=true
  while ! acquire_clean_lane_lock; do
    log "waiting because another Tart job VM is active"
    /bin/sleep 15
  done
  lane_lock_owned=true
  release_native_lane_priority
  lane_priority_requested=false

  log "cloning ${base_vm} to ${vm_name}"
  /opt/homebrew/bin/tart clone "$base_vm" "$vm_name" || {
    release_lane_lock
    lane_lock_owned=false
    failed_clone_result "$vm_name"
    return $?
  }

  cleanup_vm() {
    if [[ "$cleanup_allowed" != true ]]; then
      log "preserving ${vm_name} because safe shutdown was not proven"
      return 0
    fi
    log "deleting ${vm_name}"
    delete_vm "$vm_name" || return 1
    /bin/rm -f "$work_disk"
    [[ "$lane_lock_owned" != true ]] || release_lane_lock
    lane_lock_owned=false
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
      'set -e; root_store=$(diskutil info / | awk -F: '\''/APFS Physical Store/{gsub(/ /, "", $2); print $2; exit}'\''); root_device=$(printf "%s" "$root_store" | sed -E "s/s[0-9]+$//"); work_device=$(diskutil list physical | awk '\''/^\/dev\/disk[0-9]+ /{gsub("/dev/", "", $1); print $1}'\'' | grep -v "^${root_device}$"); test "$(printf "%s\n" "$work_device" | wc -l | tr -d " ")" = 1; printf "%s\n" "$root_device" "$work_device" | while IFS= read -r device; do printf "%s\n" "$device" | grep -Eq "^disk[0-9]+$" || exit 1; done; sudo diskutil eraseDisk APFS RunnerWork GPT "/dev/$work_device" >/dev/null; mkdir -p /Volumes/RunnerWork/_work /Volumes/RunnerWork/DerivedData /Volumes/RunnerWork/Archives /Volumes/RunnerWork/tmp /Volumes/RunnerWork/npm-cache /Volumes/RunnerWork/user-cache /Volumes/RunnerWork/core-simulator-cache /Volumes/RunnerWork/core-simulator-devices /Volumes/RunnerWork/expo /Volumes/RunnerWork/gradle /Volumes/RunnerWork/cocoapods /Volumes/RunnerWork/runner-diag /Users/admin/Library/Developer/Xcode /Users/admin/Library/Developer/CoreSimulator; sudo rm -rf /Library/Developer/CoreSimulator/Caches; sudo ln -s /Volumes/RunnerWork/core-simulator-cache /Library/Developer/CoreSimulator/Caches; xcrun simctl runtime scan-and-mount >/dev/null; runtime_ready=false; for _ in {1..45}; do if xcrun simctl list runtimes | grep -q "iOS"; then runtime_ready=true; break; fi; sleep 2; done; [ "$runtime_ready" = true ]; launchctl kill SIGKILL "gui/$(id -u)/com.apple.CoreSimulator.CoreSimulatorService" >/dev/null 2>&1 || true; sleep 2; sudo rm -rf /Users/admin/Library/Developer/Xcode/DerivedData /Users/admin/Library/Developer/Xcode/Archives /Users/admin/Library/Developer/CoreSimulator/Devices /Users/admin/Library/Caches /Users/admin/.expo /Users/admin/.gradle /Users/admin/.cocoapods /Users/admin/actions-runner/_diag; ln -s /Volumes/RunnerWork/DerivedData /Users/admin/Library/Developer/Xcode/DerivedData; ln -s /Volumes/RunnerWork/Archives /Users/admin/Library/Developer/Xcode/Archives; ln -s /Volumes/RunnerWork/core-simulator-devices /Users/admin/Library/Developer/CoreSimulator/Devices; ln -s /Volumes/RunnerWork/user-cache /Users/admin/Library/Caches; ln -s /Volumes/RunnerWork/expo /Users/admin/.expo; ln -s /Volumes/RunnerWork/gradle /Users/admin/.gradle; ln -s /Volumes/RunnerWork/cocoapods /Users/admin/.cocoapods; ln -s /Volumes/RunnerWork/runner-diag /Users/admin/actions-runner/_diag' || return 1

    ensure_installation_token || return 1
    token=$(registration_token "$github_installation_token") || return 1
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
      "IFS= read -r registration_token; export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/Volumes/RunnerWork/tmp npm_config_cache=/Volumes/RunnerWork/npm-cache; cd '$runner_root'; ./config.sh --unattended --ephemeral --disableupdate --url 'https://github.com/${repository}' --token \"\$registration_token\" --name '$runner_name' --labels '$runner_labels' --work /Volumes/RunnerWork/_work; /usr/bin/nohup ./run.sh > runner-controller.log 2>&1 < /dev/null &" || {
        cleanup_allowed=false
        return 3
      }
    runner_claimed=false

    for _ in {1..60}; do
      state=$(runner_process_state "$vm_ip")
      if [[ "$state" == worker ]]; then
        runner_claimed=true
        if supervise_claimed_runner "$vm_ip"; then
          runner_status=0
        else
          runner_status=1
        fi
        break
      fi
      /bin/sleep 5
    done
    if [[ "$runner_claimed" == false ]]; then
      state=$(stop_idle_listener "$vm_ip")
      missing_count=0
      for _ in {1..24}; do
        state=$(runner_process_state "$vm_ip")
        if [[ "$state" == worker ]]; then runner_claimed=true; break
        elif [[ "$state" == absent ]]; then (( missing_count += 1 )); (( missing_count >= 6 )) && break
        elif [[ "$state" == listener ]]; then stop_idle_listener "$vm_ip" >/dev/null; missing_count=0
        else missing_count=0
        fi
        /bin/sleep 5
      done
      if [[ "$runner_claimed" == true ]]; then
        supervise_claimed_runner "$vm_ip" && runner_status=0 || runner_status=1
      elif (( missing_count >= 6 )); then
        registration_state=$(runner_registration_state "$runner_name")
        if [[ "$registration_state" == busy ]]; then
          runner_claimed=true
          supervise_claimed_runner "$vm_ip" && runner_status=0 || runner_status=1
        elif [[ "$registration_state" == idle || "$registration_state" == missing ]]; then
          log "${runner_name} drained without accepting a job; removing it"
          delete_runner_registration "$runner_name" || true
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
    [[ "$lane_priority_requested" != true ]] || release_native_lane_priority
    lane_priority_requested=false
    if ! cleanup_vm; then
      cleanup_allowed=false
      log "VM cleanup failed; exiting for startup reconciliation"
      exit 1
    fi
    if [[ "$cleanup_allowed" == true && -n "$vm_pid" ]]; then
      wait "$vm_pid" >/dev/null 2>&1 || true
    fi
  }
  [[ "$cleanup_allowed" == true ]] || runner_status=3
  return "$runner_status"
}

main() {
  local runner_result stale_ip stale_state preserved_stale=false
  umask 077
  if ! acquire_controller_lock; then
    log "another iOS runner controller owns ${lock_directory}"
    return 0
  fi
  trap 'release_controller_lock' EXIT
  if [[ -n "$required_volume" ]] && ! /sbin/mount | /usr/bin/grep -Fq " on ${required_volume} ("; then
    log "required volume ${required_volume} is not mounted"
    return 1
  fi
  mkdir -p "$work_disk_directory"
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
      if stale_ip=$(/opt/homebrew/bin/tart ip "$stale_vm" 2>/dev/null); then
        stale_state=$(runner_process_state "$stale_ip")
        stale_state=$(reconcile_stale_runner_state "$stale_ip" "$stale_state")
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
  for stale_disk in "${work_disk_directory}"/trips-runner-job-*.raw(N); do
    log "removing stale ephemeral work disk ${stale_disk:t}"
    /bin/rm -f "$stale_disk"
  done

  while true; do
    if ! ensure_installation_token; then
      log "GitHub App authentication is unavailable; retrying in 30 seconds"
      /bin/sleep 30
    elif ! installation_api_has_headroom; then
      log "GitHub App API has less than 1,500 core requests remaining; pausing discovery for 180 seconds"
      /bin/sleep 180
    elif repository_has_queued_native_job; then
      run_one_ephemeral_runner
      runner_result=$?
      case "$runner_result" in
        0) log "ephemeral runner cycle completed" ;;
        3)
          log "preserved an ambiguous runner; exiting for startup reconciliation"
          return 1
          ;;
        *)
          log "ephemeral runner cycle failed; retrying in 30 seconds"
          /bin/sleep 30
          ;;
      esac
    else
      /bin/sleep 15
    fi
  done
}

if [[ "${TRIPS_RUNNER_CONTROLLER_TEST_MODE:-false}" != true ]]; then
  main
fi
