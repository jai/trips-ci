#!/bin/zsh
set -eu

repo_root="${0:A:h:h}"
mkdir -p "${repo_root}/tmp"
test_directory=$(mktemp -d "${repo_root}/tmp/ci-health-test.XXXXXX")
trap '/bin/rm -rf -- "$test_directory"' EXIT
fake_bin="${test_directory}/bin"
mkdir -p "$fake_bin" "${test_directory}/.credentials"
print -r -- 'AGENT_TOKEN_CLAUDE_BORG_CUBE_03=test-token
WORKER_URL=https://pager.test' > "${test_directory}/.credentials/agent-pager"
healthy='{"status":"ok","scale_sets":[{"name":"x","ready":true}]}'
print -r -- '#!/bin/zsh
shift
exec "$@"' > "${fake_bin}/gtimeout"
print -r -- "#!/bin/zsh
[[ \${FAKE_LINUX:-ok} == ok ]] || exit 1
print -r -- '${healthy}'" > "${fake_bin}/colima"
print -r -- "#!/bin/zsh
if [[ \"\$*\" == *pager.test* ]]; then
  print -r -- \"\$*\" >> '${test_directory}/pager.log'
  print -r -- '{\"id\":\"alert-1\"}'
  exit 0
fi
print -r -- '${healthy}'" > "${fake_bin}/curl"
chmod +x "${fake_bin}"/*
: > "${test_directory}/pager.log"

run_check() {
  HOME="$test_directory" PATH="${fake_bin}:${PATH}" "${repo_root}/scripts/trips-ci-health.zsh" >/dev/null
}
page_count() {
  /usr/bin/grep -c '/alert ' "${test_directory}/pager.log" || true
}
state="${test_directory}/.local/state/trips-ci-health"

run_check
[[ ! -e "${state}/failing-since" ]] || { print -u2 'Healthy CI must not record a failure'; exit 1; }

FAKE_LINUX=down run_check
[[ -s "${state}/failing-since" ]] || { print -u2 'A failure must be recorded'; exit 1; }
[[ "$(page_count)" == 0 ]] || { print -u2 'A new failure must not page'; exit 1; }

print -r -- "$(( $(/bin/date +%s) - 3601 ))" > "${state}/failing-since"
FAKE_LINUX=down run_check
FAKE_LINUX=down run_check
[[ "$(page_count)" == 1 ]] || { print -u2 'An hour of failure must page exactly once'; exit 1; }
/usr/bin/grep -q '"severity": "info"' "${test_directory}/pager.log" || { print -u2 'The page must be info'; exit 1; }

run_check
/usr/bin/grep -q '/alert/alert-1/resolve' "${test_directory}/pager.log" || { print -u2 'Recovery must resolve the page'; exit 1; }
[[ ! -e "${state}/failing-since" && ! -e "${state}/alert-id" ]] || { print -u2 'Recovery must clear state'; exit 1; }

print -r -- 'Trips CI health check passed.'
