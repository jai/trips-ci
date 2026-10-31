#!/bin/zsh
set -u

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly app_id="${TRIPS_TART_GITHUB_APP_ID:-4452026}"
readonly installation_id="${TRIPS_TART_GITHUB_INSTALLATION_ID:-150444191}"
readonly repositories="${TRIPS_TART_REPOSITORIES:-jai/trips-frontend,jai/tonegate}"
readonly -a repository_list=(${(s:,:)repositories})
readonly base_vm="${TRIPS_TART_BASE_VM:-trips-runner-base}"
readonly base_cpus="${TRIPS_TART_BASE_CPUS:-4}"
readonly base_memory_mb="${TRIPS_TART_BASE_MEMORY_MB:-16384}"
readonly allowed_coresident_vms="${TRIPS_TART_ALLOWED_CORESIDENT_VMS:-}"
readonly runner_root="/Users/admin/actions-runner"
readonly runner_host_label="${TRIPS_TART_RUNNER_HOST_LABEL:-borg-cube-03}"
readonly runner_name_prefix="${TRIPS_TART_RUNNER_NAME_PREFIX:-${runner_host_label}}"
# Host placement is controller-owned. GitHub workflows use durable capability
# labels so another eligible Borg controller can claim a job after host failure.
readonly runner_labels="${TRIPS_TART_RUNNER_LABELS:-tart,ios}"
readonly private_key="/Users/jai/.config/trips-tart-runner/github-app-private-key.pem"
readonly ssh_key="/Users/jai/.config/trips-tart-runner/runner-controller-ed25519"
readonly log_directory="/Users/jai/Library/Logs/trips-tart-runner"
readonly work_disk_directory="${TRIPS_TART_WORK_DISK_DIRECTORY:-/Users/jai/.local/share/trips-tart-runner/work-disks}"
readonly controller_lock="${TRIPS_TART_CONTROLLER_LOCK:-${log_directory}/controller.lock}"
readonly native_lane_lock="${TRIPS_TART_NATIVE_LANE_LOCK:-/Users/jai/Library/Logs/trips-tart-native-lane.lock}"
readonly native_lane_controllers='trips-tart-runner-controller'
readonly minimum_root_free_gib="${TRIPS_TART_MINIMUM_ROOT_FREE_GIB:-20}"
readonly required_volume="${TRIPS_TART_REQUIRED_VOLUME:-}"
readonly gh_cli="${TRIPS_TART_GH_CLI:-/opt/homebrew/bin/gh}"
readonly curl_cli="${TRIPS_TART_CURL_CLI:-/usr/bin/curl}"
readonly tart_cli="${TRIPS_TART_CLI:-/opt/homebrew/bin/tart}"
readonly shlock_cli="${TRIPS_TART_SHLOCK_CLI:-/usr/bin/shlock}"
readonly lima_cli="${TRIPS_TART_LIMA_CLI:-/opt/homebrew/bin/limactl}"
readonly iostat_cli="${TRIPS_TART_IOSTAT_CLI:-/usr/sbin/iostat}"
readonly sysctl_cli="${TRIPS_TART_SYSCTL_CLI:-/usr/sbin/sysctl}"
# Host-wide CI policy, shared with the Lima controller; keep both copies equal.
readonly budget_lock="${TRIPS_CI_BUDGET_LOCK:-/Users/jai/Library/Logs/trips-ci-vm-budget.lock}"
readonly budget_controllers='trips-(linux-lima-runner|tart-runner)-controller'
readonly budget_cpus="${TRIPS_CI_BUDGET_CPUS:-7}"
readonly budget_memory_gib="${TRIPS_CI_BUDGET_MEMORY_GIB:-24}"
readonly host_min_cpu_idle_percent="${TRIPS_CI_HOST_MIN_CPU_IDLE_PERCENT:-40}"
readonly host_max_load_average="${TRIPS_CI_HOST_MAX_LOAD_AVERAGE:-400}"
readonly host_memory_reserve_gib="${TRIPS_CI_HOST_MEMORY_RESERVE_GIB:-16}"
readonly host_cpu_sample_seconds="${TRIPS_CI_HOST_CPU_SAMPLE_SECONDS:-5}"
readonly claim_timeout_seconds="${TRIPS_TART_CLAIM_TIMEOUT_SECONDS:-300}"
readonly claim_poll_seconds="${TRIPS_TART_CLAIM_POLL_SECONDS:-2}"
readonly idle_scan_interval_seconds="${TRIPS_TART_IDLE_SCAN_INTERVAL_SECONDS:-30}"
readonly network_mode="${TRIPS_TART_NETWORK_MODE:-shared}"
readonly native_capacity_deferred_status=75

typeset -g installation_token_value=""
typeset -g installation_token_expires_at=0
typeset -g selected_repository=""
typeset -g native_lane_lock_owned=false
typeset -g native_lane_release_failed=false
typeset -g native_capacity_reason=""
typeset -g capacity_wait=false

export TART_HOME="${TART_HOME:-/Users/jai/.tart}"

timestamp() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  print -r -- "$(timestamp) $*"
}

# shlock trusts any live PID, but PIDs recycle across reboots: from 2026-10-21
# to 10-29 a Batteries widget held this controller's old PID 727 and blocked
# every start. An owner counts only while its command line runs a controller.
lock_owner_is_controller() {
  local owner_pid="$1" controllers="$2" command_line
  [[ "$owner_pid" == <1-> && "$owner_pid" != $$ ]] || return 1
  command_line=$(/bin/ps -ww -o command= -p "$owner_pid" 2>/dev/null) || return 1
  [[ " ${command_line} " == *[/\ ]${~controllers}(|.zsh)\ * ]]
}

read_lock_owner() {
  REPLY=""
  [[ -r "$1" ]] && read -r REPLY <"$1"
  return 0
}

acquire_lock() {
  local lock_path="$1" controllers="$2" guard="${1}.takeover" takeover_status=1
  "$shlock_cli" -f "$lock_path" -p $$ && return 0
  read_lock_owner "$lock_path"
  # A lock that already names this PID is ours, even if an earlier process
  # with the same recycled PID wrote it.
  [[ "$REPLY" == $$ ]] && return 0
  lock_owner_is_controller "$REPLY" "$controllers" && return 1
  # Serialize the takeover so two contenders cannot both delete and recreate
  # the lock. A guard left by a dead or recycled PID is cleared for the retry.
  if ! "$shlock_cli" -f "$guard" -p $$; then
    read_lock_owner "$guard"
    lock_owner_is_controller "$REPLY" "$controllers" || /bin/rm -f "$guard"
    return 1
  fi
  read_lock_owner "$lock_path"
  if ! lock_owner_is_controller "$REPLY" "$controllers"; then
    log "taking over ${lock_path} from PID ${REPLY:-none}, which is not a runner controller"
    /bin/rm -f "$lock_path"
    "$shlock_cli" -f "$lock_path" -p $$ && takeover_status=0
  fi
  /bin/rm -f "$guard"
  return "$takeover_status"
}

release_lock() {
  local lock_path="$1" owner_pid=""
  [[ -r "$lock_path" ]] && read -r owner_pid <"$lock_path"
  [[ "$owner_pid" != $$ ]] || /bin/rm -f "$lock_path"
}

acquire_controller_lock() { acquire_lock "$controller_lock" trips-tart-runner-controller; }
release_controller_lock() { release_lock "$controller_lock"; }
release_native_lane() {
  [[ "$native_lane_lock_owned" == true ]] || return 0
  release_lock "$native_lane_lock" || {
    local release_status=$?
    native_lane_release_failed=true
    return "$release_status"
  }
  native_lane_lock_owned=false
  native_lane_release_failed=false
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

registration_token() {
  local repository="$1" token
  installation_token || return 1
  token="$REPLY"
  REPLY=$(
    "$curl_cli" -fsS --connect-timeout 10 --max-time 20 -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners/registration-token" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
  ) || return 1
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
  installation_token_value=$(
    "$curl_cli" -fsS --connect-timeout 10 --max-time 20 -X POST \
    -H "Authorization: Bearer $jwt" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/app/installations/${installation_id}/access_tokens" |
    /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
  ) || return 1
  installation_token_expires_at=$((now + 480))
  REPLY="$installation_token_value"
}

runner_lookup() {
  local repository="$1" runner_name="$2" token page response result count
  installation_token || return 1
  token="$REPLY"
  page=1
  while true; do
    response=$(
      "$curl_cli" -fsS --connect-timeout 10 --max-time 20 \
        -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/repos/${repository}/actions/runners?per_page=100&page=${page}"
    ) || return 1
    result=$(printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys
data=json.load(sys.stdin); name=sys.argv[1]
runner=next((r for r in data.get("runners",[]) if r.get("name") == name), None)
print((str(runner["id"]) + "\t" + ("busy" if runner.get("busy") else "idle") + "\t" + ",".join(str(label.get("name", "")).lower() for label in runner.get("labels", []))) if runner else "")' "$runner_name") || return 1
    if [[ -n "$result" ]]; then
      REPLY="$result"
      return 0
    fi
    count=$(printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("runners",[])))') || return 1
    (( count < 100 )) && break
    page=$((page + 1))
  done
  REPLY=$'\tmissing'
}

runner_busy_state() {
  local repository="$1" runner_name="$2" lookup
  runner_lookup "$repository" "$runner_name" || return 1
  lookup="$REPLY"
  REPLY="${lookup#*$'\t'}"
  REPLY="${REPLY%%$'\t'*}"
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

repository_workflow_runs() {
  local repository="$1" run_status
  # GitHub keeps a run in "pending" while a concurrency queue (maestro-ios `queue: max`)
  # holds it, yet its jobs are already queued, so pending runs must be scanned too.
  for run_status in queued in_progress pending; do
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
required={"self-hosted","macos","arm64","tart","ios"}
pages=json.load(sys.stdin)
jobs=[job for page in pages for job in page.get("jobs",[])]
matches=[job.get("created_at","") for job in jobs if job.get("status") == "queued" and {str(label).lower() for label in job.get("labels",[])} == required and job.get("created_at")]
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

wait_for_runner_claim() {
  local repository="$1" runner_name="$2" runner_pid="$3" started_at now state
  started_at=$(/bin/date +%s)
  while /bin/kill -0 "$runner_pid" 2>/dev/null; do
    if runner_busy_state "$repository" "$runner_name"; then
      state="$REPLY"
      if [[ "$state" == busy ]]; then
        return 0
      fi
    else
      state=unknown
      log "unable to verify ${runner_name} claim state; preserving runner"
    fi
    now=$(/bin/date +%s)
    if (( now - started_at >= claim_timeout_seconds )); then
      if [[ "$state" == idle || "$state" == missing ]]; then
        return 2
      fi
    fi
    /bin/sleep "$claim_poll_seconds"
  done
  return 1
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

delete_vm() {
  local vm_name="$1" inventory
  "$tart_cli" stop "$vm_name" >/dev/null 2>&1 || true
  "$tart_cli" delete "$vm_name" >/dev/null 2>&1 || true
  inventory=$("$tart_cli" list --source local --quiet 2>/dev/null) || {
    log "unable to verify deletion of ${vm_name}"
    return 1
  }
  if printf '%s\n' "$inventory" | /usr/bin/grep -qx "$vm_name"; then
    log "failed to delete ${vm_name}"
    return 1
  fi
}

list_ephemeral_vms() {
  local inventory vm_name
  inventory=$("$tart_cli" list --source local --quiet 2>/dev/null) || {
    log "unable to inventory Tart VMs"
    return 1
  }
  while IFS= read -r vm_name; do
    [[ "$vm_name" == trips-runner-job-* ]] && print -r -- "$vm_name"
  done <<< "$inventory"
  return 0
}

reconcile_startup_ephemeral_vms() {
  local inventory rows vm_name vm_state preserved
  preserved=false
  inventory=$("$tart_cli" list --source local --format json 2>/dev/null) || {
    log "unable to reconcile startup Tart VMs"
    return 2
  }
  rows=$(printf '%s' "$inventory" | /usr/bin/python3 -c 'import json,sys
for vm in json.load(sys.stdin):
    name=str(vm.get("Name", ""))
    if name.startswith("trips-runner-job-"):
        print("{}\t{}".format(name, vm.get("State", "unknown")))') || return 2
  while IFS=$'\t' read -r vm_name vm_state; do
    [[ -n "$vm_name" ]] || continue
    if [[ "$vm_state" == stopped ]]; then
      log "removing safely stopped stale ephemeral VM ${vm_name}"
      delete_vm "$vm_name" || return 2
    else
      log "preserving ${vm_name}; live state is ${vm_state:-unknown}"
      preserved=true
    fi
  done <<< "$rows"
  [[ "$preserved" == false ]]
}

native_capacity_available() {
  local inventory
  inventory=$("$tart_cli" list --source local --format json 2>/dev/null) || {
    REPLY=""
    return 2
  }
  REPLY=$(printf '%s' "$inventory" | TRIPS_TART_ALLOWED_CORESIDENT_VMS="$allowed_coresident_vms" /usr/bin/python3 -c 'import json,os,sys
vms=json.load(sys.stdin)
allowed={name.strip() for name in os.environ["TRIPS_TART_ALLOWED_CORESIDENT_VMS"].split(",") if name.strip()}
print("\n".join(str(vm.get("Name", "")) for vm in vms if vm.get("Name") and vm.get("Name") not in allowed and (vm.get("Running") is True or vm.get("State") != "stopped")))') || {
    REPLY=""
    return 2
  }
  [[ -z "$REPLY" ]]
}

acquire_clean_native_lane() {
  if ! acquire_lock "$native_lane_lock" "$native_lane_controllers"; then
    REPLY="$native_lane_lock"
    return 3
  fi
  native_lane_lock_owned=true
  if native_capacity_available; then
    return 0
  else
    local capacity_status=$?
  fi
  release_native_lane
  return "$capacity_status"
}

# Sum the vCPUs and MiB assigned to every CI job VM, running or not, so a VM
# that is still being cloned counts against the budget.
ci_vm_allocation() {
  setopt local_options pipe_fail
  local lima_inventory tart_inventory tart_vm tart_vm_config
  local -a allocation
  lima_inventory=$("$lima_cli" list --json 2>/dev/null) || return 1
  allocation=($(printf '%s\n' "$lima_inventory" | /usr/bin/python3 -c 'import json,sys
cpus=memory=0
for line in sys.stdin:
    if line.strip():
        vm=json.loads(line)
        if vm["name"].startswith("trips-linux-runner-") and "-job-" in vm["name"]:
            cpus+=int(vm.get("cpus") or 0); memory+=int(vm.get("memory") or 0)//1048576
print(cpus, memory)')) || return 1
  tart_inventory=$("$tart_cli" list --source local --quiet 2>/dev/null) || return 1
  for tart_vm in ${(f)tart_inventory}; do
    [[ "$tart_vm" == trips-runner-job-* ]] || continue
    tart_vm_config=$("$tart_cli" get "$tart_vm" --format json 2>/dev/null) || return 1
    allocation=($(printf '%s' "$tart_vm_config" | /usr/bin/python3 -c 'import json,sys
vm=json.load(sys.stdin)
print(int(sys.argv[1])+int(vm["CPU"]), int(sys.argv[2])+int(vm["Memory"]))' "${allocation[@]}")) || return 1
  done
  REPLY="${allocation[*]}"
}

# The laptop's load average overstates real load: darwinbg simulator threads
# queue for its two efficiency cores (184 at 31% CPU idle on 2026-10-30), so
# it only catches thread storms (1,007 on 2026-10-29). Measured CPU idle and
# the kernel's memory pressure decide.
host_capacity_available() {
  local vm_memory_gib="$1" sample pressure available_percent memory_bytes
  local -a fields reasons
  local -i available_gib
  sample=$("$iostat_cli" -n 0 -c 2 -w "$host_cpu_sample_seconds" 2>/dev/null | /usr/bin/tail -n 1)
  fields=(${=sample})
  # iostat columns: us sy id 1m 5m 15m; the last row covers the sample interval.
  if (( ${#fields} != 6 )) || [[ "${fields[3]}" != <-> ]]; then
    REPLY="unable to sample host CPU"
    return 1
  fi
  pressure=$("$sysctl_cli" -n kern.memorystatus_vm_pressure_level 2>/dev/null)
  available_percent=$("$sysctl_cli" -n kern.memorystatus_level 2>/dev/null)
  memory_bytes=$("$sysctl_cli" -n hw.memsize 2>/dev/null)
  if [[ "$pressure" != <-> || "$available_percent" != <-> || "$memory_bytes" != <-> ]]; then
    REPLY="unable to read host memory pressure"
    return 1
  fi
  available_gib=$((memory_bytes / 1073741824 * available_percent / 100))
  reasons=()
  (( fields[3] >= host_min_cpu_idle_percent )) ||
    reasons+=("CPU ${fields[3]}% idle, need ${host_min_cpu_idle_percent}%")
  (( fields[4] < host_max_load_average )) ||
    reasons+=("load average ${fields[4]}, limit ${host_max_load_average}")
  (( pressure == 1 )) || reasons+=("memory pressure level ${pressure}")
  [[ -z "${TRIPS_CI_HOST_ALLOWED_DAYS:-}" || ",${TRIPS_CI_HOST_ALLOWED_DAYS}," == *,$(/bin/date +%u),* ]] ||
    reasons+=("today is outside CI days ${TRIPS_CI_HOST_ALLOWED_DAYS}")
  (( available_gib - vm_memory_gib >= host_memory_reserve_gib )) ||
    reasons+=("${available_gib} GiB available, need ${vm_memory_gib} GiB plus ${host_memory_reserve_gib} GiB reserve")
  REPLY="${(j:; :)reasons}"
  (( ${#reasons} == 0 ))
}

# After a deferral, wait here instead of rescanning GitHub, which costs Jai's
# token quota on every pass. Take the budget claim as soon as it is free so
# Linux slots cannot fill the budget while the iOS VM waits.
capacity_ready() {
  local vm_cpus="$1" vm_memory_gib="$2"
  local -a allocation
  acquire_lock "$budget_lock" "$budget_controllers" || return 1
  host_capacity_available "$vm_memory_gib" || return 1
  ci_vm_allocation || return 1
  allocation=(${=REPLY})
  (( allocation[1] + vm_cpus <= budget_cpus && allocation[2] + vm_memory_gib * 1024 <= budget_memory_gib * 1024 ))
}

# CI shares Jai's working laptop. Start the VM only while the host is not busy
# and every CI job VM, this one included, fits the fixed budget. iOS work has
# priority, so a deferred reservation keeps the budget lock: Linux slots cannot
# start new VMs until this VM fits. The caller releases it once its VM exists.
reserve_vm_capacity() {
  local vm_cpus="$1" vm_memory_gib="$2"
  local -a allocation
  if ! acquire_lock "$budget_lock" "$budget_controllers"; then
    REPLY="another controller has reserved the CI budget"
    return 1
  fi
  if ! host_capacity_available "$vm_memory_gib"; then
    REPLY="host busy: ${REPLY}"
    return 1
  fi
  if ! ci_vm_allocation; then
    REPLY="unable to inventory CI VMs"
    return 1
  fi
  allocation=(${=REPLY})
  if (( allocation[1] + vm_cpus > budget_cpus || allocation[2] + vm_memory_gib * 1024 > budget_memory_gib * 1024 )); then
    REPLY="CI budget ${budget_cpus} vCPU / ${budget_memory_gib} GiB has ${allocation[1]} vCPU / $((allocation[2] / 1024)) GiB in use; this VM needs ${vm_cpus} vCPU / ${vm_memory_gib} GiB"
    return 1
  fi
}

start_tart_vm() {
  local vm_name="$1" work_disk="$2" vm_log="$3" requested_network_mode="${4:-$network_mode}"
  local -a network_arguments
  network_arguments=()
  case "$requested_network_mode" in
    shared) ;;
    softnet) network_arguments=(--net-softnet) ;;
    *)
      log "unsupported Tart network mode ${requested_network_mode}"
      return 1
      ;;
  esac
  "$tart_cli" run --no-graphics --no-audio --no-clipboard \
    "${network_arguments[@]}" --disk="$work_disk" "$vm_name" >"$vm_log" 2>&1 &
  REPLY=$!
}

runner_home_cache_setup_command() {
  local home_root="$1" work_root="$2"
  printf 'mkdir -p %q %q %q; rm -rf %q %q; ln -s %q %q; ln -s %q %q' \
    "${work_root}/maestro" \
    "${work_root}/maestro-logs" \
    "${home_root}/Library/Logs" \
    "${home_root}/.maestro" \
    "${home_root}/Library/Logs/maestro" \
    "${work_root}/maestro" \
    "${home_root}/.maestro" \
    "${work_root}/maestro-logs" \
    "${home_root}/Library/Logs/maestro"
}

runner_environment_setup_command() {
  local work_root="$1"
  printf 'export PATH=%q TMPDIR=%q TMP=%q TEMP=%q JAVA_TOOL_OPTIONS=%q XDG_CACHE_HOME=%q npm_config_cache=%q' \
    '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin' \
    "${work_root}/tmp" \
    "${work_root}/tmp" \
    "${work_root}/tmp" \
    "-Djava.io.tmpdir=${work_root}/java-tmp" \
    "${work_root}/user-cache" \
    "${work_root}/npm-cache"
}

guest_preflight_script_prefix() {
  cat <<'SCRIPT'
set -e
preflight_stage=bootstrap
preflight_fail() {
  local failure_status=$?
  print -u2 -- "guest-preflight failed stage=${preflight_stage} status=${failure_status}"
  exit "$failure_status"
}
trap preflight_fail ERR
SCRIPT
}

guest_preflight_java_command() {
  printf '%s' '/opt/homebrew/bin/java -version >/dev/null 2>&1'
}

guest_clock_sync_command() {
  local host_epoch="$1"
  [[ "$host_epoch" == <-> ]] || return 1
  cat <<SCRIPT
host_epoch=${host_epoch}
guest_epoch=\$(date +%s)
clock_skew=\$(( guest_epoch - host_epoch ))
if (( clock_skew < -60 || clock_skew > 60 )); then
  sudo date -u -f %s "\$host_epoch" >/dev/null
fi
guest_epoch=\$(date +%s)
clock_skew=\$(( guest_epoch - host_epoch ))
(( clock_skew >= -60 && clock_skew <= 60 ))
SCRIPT
}

guest_runner_start_script() {
  cat <<'SCRIPT'
configure_and_run() {
  ./config.sh "$@" || return $?
  exec ./run.sh
}
SCRIPT
}

cleanup_runner_vm() {
  local repository="$1" runner_name="$2" vm_name="$3" work_disk="$4"
  log "deleting ${vm_name}"
  delete_vm "$vm_name" || return 1
  /bin/rm -f "$work_disk" || return 1
  delete_runner_registration "$repository" "$runner_name" || true
}

resolve_runner_status() {
  local claim_result="$1" runner_pid="$2" runner_name="$3"
  REPLY=1
  case "$claim_result" in
    0)
      log "${runner_name} claimed a job"
      REPLY=0
      wait "$runner_pid" || REPLY=1
      ;;
    1)
      REPLY=0
      wait "$runner_pid" || REPLY=1
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

runner_cycle_status() {
  local operation_status="$1" cleanup_status="$2"
  (( cleanup_status == 0 )) || return 1
  case "$operation_status" in
    0) return 0 ;;
    "$native_capacity_deferred_status") return "$native_capacity_deferred_status" ;;
    *) return 1 ;;
  esac
}

runner_cycle_log_message() {
  local cycle_status="$1" repository="$2"
  case "$cycle_status" in
    0) REPLY="ephemeral runner completed a job for ${repository}" ;;
    "$native_capacity_deferred_status")
      REPLY="waiting for exclusive native capacity before serving ${repository}: ${native_capacity_reason}"
      ;;
    *) REPLY="ephemeral runner cycle failed for ${repository}; retrying in 30 seconds" ;;
  esac
}

run_one_ephemeral_runner() {
  local repository="$1" suffix vm_name vm_log vm_pid vm_ip token runner_name runner_pid runner_status work_disk ssh_ready lane_status cleanup_status operation_status runner_home_cache_setup runner_environment_setup
  suffix="$(/bin/date -u '+%Y%m%d%H%M%S')-$$"
  vm_name="trips-runner-job-${suffix}"
  runner_name="${runner_name_prefix}-${suffix}"
  vm_log="${log_directory}/${vm_name}.log"
  work_disk="${work_disk_directory}/${vm_name}.raw"
  vm_pid=""
  runner_pid=""
  runner_status=1
  operation_status=1
  native_capacity_reason=""

  if ! repository_is_private "$repository"; then
    log "refusing non-private or unavailable repository ${repository}"
    return 1
  fi

  if acquire_clean_native_lane; then
    :
  else
    lane_status=$?
    (( lane_status == 2 )) && return 1
    native_capacity_reason="$REPLY"
    # Another native VM, not the budget, blocks this job; do not hold Linux back.
    release_lock "$budget_lock"
    return "$native_capacity_deferred_status"
  fi

  if ! reserve_vm_capacity "$base_cpus" "$((base_memory_mb / 1024))"; then
    native_capacity_reason="$REPLY"
    capacity_wait=true
    release_native_lane
    return "$native_capacity_deferred_status"
  fi

  log "cloning ${base_vm} to ${vm_name}"
  "$tart_cli" clone "$base_vm" "$vm_name" || {
    release_lock "$budget_lock"
    release_native_lane
    return 1
  }
  # The VM now counts in the inventory, so other controllers can recheck the budget.
  release_lock "$budget_lock"

  cleanup_vm() {
    cleanup_runner_vm "$repository" "$runner_name" "$vm_name" "$work_disk"
  }
  trap 'cleanup_vm || exit 1; exit 130' INT TERM

  {
    while true; do
      "$tart_cli" set "$vm_name" --random-mac --random-serial || break
      /usr/sbin/mkfile -n 60g "$work_disk" || break

      if native_capacity_available; then
        :
      else
        lane_status=$?
        if (( lane_status == 1 )); then
          native_capacity_reason="${(j:, :)${(f)REPLY}}"
          log "yielding before Tart start because another native VM became active: ${native_capacity_reason}"
          operation_status="$native_capacity_deferred_status"
          break
        fi
        log "unable to verify native capacity before Tart start"
        break
      fi
      log "starting ${vm_name}"
      start_tart_vm "$vm_name" "$work_disk" "$vm_log" || break
      vm_pid="$REPLY"
      vm_ip=$("$tart_cli" ip "$vm_name" --wait 180) || break
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
      [[ "$ssh_ready" == true ]] || break
      log "${vm_name} booted"
      runner_home_cache_setup=$(runner_home_cache_setup_command /Users/admin /Volumes/RunnerWork) || break
      runner_environment_setup=$(runner_environment_setup_command /Volumes/RunnerWork) || break

      /usr/bin/ssh \
      -o BatchMode=yes \
      -o ConnectTimeout=30 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -i "$ssh_key" \
      "admin@${vm_ip}" \
      "$(guest_preflight_script_prefix); preflight_stage=clock; $(guest_clock_sync_command "$(/bin/date +%s)"); preflight_stage=xcode; xcodebuild -version >/dev/null; preflight_stage=java; $(guest_preflight_java_command); preflight_stage=runner-listener; test -x /Users/admin/actions-runner/bin/Runner.Listener; preflight_stage=guest-root-free-space; test \"\$(df -g / | awk 'NR == 2 {print \$4}')\" -ge '${minimum_root_free_gib}'; preflight_stage=work-disk-discovery; root_store=\$(diskutil info / | awk -F: '/APFS Physical Store/{gsub(/ /, \"\", \$2); print \$2; exit}'); root_device=\$(printf \"%s\" \"\$root_store\" | sed -E \"s/s[0-9]+\$//\"); work_device=\$(diskutil list physical | awk '/^\\/dev\\/disk[0-9]+ /{gsub(\"/dev/\", \"\", \$1); print \$1}' | grep -v \"^\${root_device}\$\"); test \"\$(printf \"%s\\n\" \"\$work_device\" | wc -l | tr -d \" \")\" = 1; printf \"%s\\n\" \"\$root_device\" \"\$work_device\" | while IFS= read -r device; do printf \"%s\\n\" \"\$device\" | grep -Eq \"^disk[0-9]+\$\" || exit 1; done; preflight_stage=work-disk-format; sudo diskutil eraseDisk APFS RunnerWork GPT \"/dev/\$work_device\" >/dev/null; preflight_stage=work-disk-paths; mkdir -p /Volumes/RunnerWork/_work /Volumes/RunnerWork/DerivedData /Volumes/RunnerWork/Archives /Volumes/RunnerWork/tmp /Volumes/RunnerWork/java-tmp /Volumes/RunnerWork/npm-cache /Volumes/RunnerWork/user-cache /Volumes/RunnerWork/core-simulator-cache /Volumes/RunnerWork/core-simulator-devices /Volumes/RunnerWork/expo /Volumes/RunnerWork/gradle /Volumes/RunnerWork/cocoapods /Volumes/RunnerWork/runner-diag /Users/admin/Library/Developer/Xcode /Users/admin/Library/Developer/CoreSimulator; test -w /Volumes/RunnerWork/tmp; test \"\$(df -g /Volumes/RunnerWork | awk 'NR == 2 {print \$4}')\" -ge 50; preflight_stage=maestro-cache-paths; ${runner_home_cache_setup}; preflight_stage=simulator-runtime; sudo rm -rf /Library/Developer/CoreSimulator/Caches; sudo ln -s /Volumes/RunnerWork/core-simulator-cache /Library/Developer/CoreSimulator/Caches; xcrun simctl runtime scan-and-mount >/dev/null; runtime_ready=false; for _ in {1..45}; do if xcrun simctl list runtimes | grep -q \"iOS\"; then runtime_ready=true; break; fi; sleep 2; done; [ \"\$runtime_ready\" = true ]; preflight_stage=runner-cache-links; launchctl kill SIGKILL \"gui/\$(id -u)/com.apple.CoreSimulator.CoreSimulatorService\" >/dev/null 2>&1 || true; sleep 2; sudo rm -rf /Users/admin/Library/Caches || true; sudo rm -rf /Users/admin/Library/Developer/Xcode/DerivedData /Users/admin/Library/Developer/Xcode/Archives /Users/admin/Library/Developer/CoreSimulator/Devices /Users/admin/.expo /Users/admin/.gradle /Users/admin/.cocoapods /Users/admin/actions-runner/_diag; ln -s /Volumes/RunnerWork/DerivedData /Users/admin/Library/Developer/Xcode/DerivedData; ln -s /Volumes/RunnerWork/Archives /Users/admin/Library/Developer/Xcode/Archives; ln -s /Volumes/RunnerWork/core-simulator-devices /Users/admin/Library/Developer/CoreSimulator/Devices; if [ ! -e /Users/admin/Library/Caches ]; then ln -s /Volumes/RunnerWork/user-cache /Users/admin/Library/Caches; fi; ln -s /Volumes/RunnerWork/expo /Users/admin/.expo; ln -s /Volumes/RunnerWork/gradle /Users/admin/.gradle; ln -s /Volumes/RunnerWork/cocoapods /Users/admin/.cocoapods; ln -s /Volumes/RunnerWork/runner-diag /Users/admin/actions-runner/_diag" || break

      registration_token "$repository" || break
      token="$REPLY"
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
      "set -e; IFS= read -r registration_token; ${runner_environment_setup}; $(guest_runner_start_script); cd '$runner_root'; configure_and_run --unattended --ephemeral --disableupdate --url 'https://github.com/${repository}' --token \"\$registration_token\" --name '$runner_name' --labels '$runner_labels' --work /Volumes/RunnerWork/_work" &
      runner_pid=$!
      wait_for_runner_claim "$repository" "$runner_name" "$runner_pid"
      local claim_result=$?
      resolve_runner_status "$claim_result" "$runner_pid" "$runner_name" || break
      runner_status="$REPLY"
      operation_status="$runner_status"
      break
    done
  } always {
    trap - INT TERM
    cleanup_status=0
    cleanup_vm || cleanup_status=$?
    [[ -z "$vm_pid" ]] || wait "$vm_pid" >/dev/null 2>&1 || true
    release_native_lane || cleanup_status=$?
  }
  runner_cycle_status "$operation_status" "$cleanup_status"
}

main() {
  local repository stale_vms
  local -i scan_status
  umask 077
  mkdir -p "$log_directory"
  if ! acquire_controller_lock; then
    log "another iOS runner controller owns ${controller_lock}"
    return 1
  fi
  trap 'release_native_lane; release_lock "$budget_lock"; release_controller_lock' EXIT
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
  if ! "$tart_cli" list --source local --quiet | /usr/bin/grep -qx "${base_vm}"; then
    log "base VM ${base_vm} is missing"
    return 1
  fi
  if [[ "$base_cpus" != 4 || "$base_memory_mb" != 16384 ]]; then
    log "resource contract requires 4 CPUs and 16384 MB for iOS"
    return 1
  fi
  if (( base_cpus > budget_cpus || base_memory_mb > budget_memory_gib * 1024 )); then
    log "the iOS VM exceeds the CI budget of ${budget_cpus} vCPU / ${budget_memory_gib} GiB"
    return 1
  fi
  if ! "$tart_cli" set "$base_vm" --cpu "$base_cpus" --memory "$base_memory_mb"; then
    log "failed to apply the iOS base resource contract"
    return 1
  fi

  reconcile_startup_ephemeral_vms || return 1
  for stale_disk in "${work_disk_directory}"/trips-runner-job-*.raw(N); do
    log "removing stale ephemeral work disk ${stale_disk:t}"
    /bin/rm -f "$stale_disk" || return 1
  done

  while true; do
    if [[ "$capacity_wait" == true ]]; then
      if ! capacity_ready "$base_cpus" "$((base_memory_mb / 1024))"; then
        /bin/sleep "$idle_scan_interval_seconds"
        continue
      fi
      capacity_wait=false
    fi
    if next_repository; then
      repository="$selected_repository"
      run_one_ephemeral_runner "$repository"
      scan_status=$?
      if [[ "$native_lane_release_failed" == true ]]; then
        log "native-lane unlock failed; terminating controller for supervised recovery"
        return 1
      fi
      runner_cycle_log_message "$scan_status" "$repository"
      log "$REPLY"
      case "$scan_status" in
        0) ;;
        "$native_capacity_deferred_status")
          /bin/sleep "$idle_scan_interval_seconds"
          ;;
        *)
          # Only a deferred reservation keeps its budget claim.
          release_lock "$budget_lock"
          /bin/sleep 30
          ;;
      esac
    else
      scan_status=$?
      # No iOS job is waiting any more, so drop a deferred budget claim.
      release_lock "$budget_lock"
      if (( scan_status == 1 )); then
        /bin/sleep "$idle_scan_interval_seconds"
      else
        log "GitHub queue scan failed; retrying in 15 seconds"
        /bin/sleep 15
      fi
    fi
  done
}

if [[ "${TRIPS_RUNNER_CONTROLLER_LIBRARY_ONLY:-false}" != true ]]; then
  main
fi
