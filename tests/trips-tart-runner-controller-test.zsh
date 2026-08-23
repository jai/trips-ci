#!/bin/zsh
set -eu

repo_root="${0:A:h:h}"
mkdir -p "${repo_root}/tmp"
test_directory=$(mktemp -d "${repo_root}/tmp/tart-controller-test.XXXXXX")
trap '/bin/rm -rf -- "$test_directory"' EXIT

fake_gh="${test_directory}/gh"
cat > "$fake_gh" <<'SCRIPT'
#!/bin/zsh
set -eu

request="$*"
case "${FAKE_SCENARIO:-}" in
  tonegate-only)
    if [[ "$request" == *'repos/jai/tonegate/actions/runs?'* ]]; then
      print -r -- $'101\tjai/tonegate'
    elif [[ "$request" == *'repos/jai/tonegate/actions/runs/101/jobs?'* ]]; then
      print -r -- '1'
    fi
    ;;
  trips-first)
    if [[ "$request" == *'repos/jai/trips-frontend/actions/runs?'* ]]; then
      print -r -- $'202\tjai/trips-frontend'
    elif [[ "$request" == *'repos/jai/trips-frontend/actions/runs/202/jobs?'* ]]; then
      if [[ "$request" == *'index("borg-cube-03")'* ]]; then
        print -u2 -- 'Queued-job detection must not require a controller-specific host label'
        exit 1
      fi
      print -r -- '1'
    fi
    ;;
  no-jobs)
    ;;
  *)
    print -u2 -- "Unknown fake scenario"
    exit 1
    ;;
esac
SCRIPT
chmod 700 "$fake_gh"

export TRIPS_RUNNER_CONTROLLER_LIBRARY_ONLY=true
export TRIPS_TART_GH_CLI="$fake_gh"
export TRIPS_TART_REPOSITORIES='jai/trips-frontend,jai/tonegate'
source "${repo_root}/scripts/trips-tart-runner-controller.zsh"

assert_equal() {
  local expected="$1" actual="$2"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 -- "Expected '$expected', got '$actual'"
    return 1
  fi
}

export FAKE_SCENARIO=tonegate-only
assert_equal 'jai/tonegate' "$(next_repository)"
export FAKE_SCENARIO=trips-first
assert_equal 'jai/trips-frontend' "$(next_repository)"
export FAKE_SCENARIO=no-jobs
if next_repository >/dev/null; then
  print -u2 -- 'Expected no queued repository'
  exit 1
fi

print -r -- 'Tart controller repository selection passed.'
