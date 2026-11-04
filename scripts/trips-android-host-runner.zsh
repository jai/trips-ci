#!/bin/zsh
# One ephemeral Android runner for one job; launchd starts the next one.
set -eu
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly root=/Users/jai/.local/share/trips-android-host-runner
readonly job_root="$root/jobs/job-$(date +%s)"

rm -rf "$root"/jobs/job-*
mkdir -p "$job_root/tmp" "$job_root/npm" "$job_root/gradle" "$job_root/work"
cp -R "$root/actions-runner" "$job_root/runner"
token=$(gh api -X POST repos/jai/trips-frontend/actions/runners/registration-token --jq .token)

export TMPDIR="$job_root/tmp" npm_config_cache="$job_root/npm" GRADLE_USER_HOME="$job_root/gradle"
export ANDROID_SDK_ROOT=/Users/jai/Library/Android/sdk ANDROID_HOME=/Users/jai/Library/Android/sdk
export ANDROID_USER_HOME=/Users/jai/.android ANDROID_AVD_HOME=/Users/jai/.android/avd

cd "$job_root/runner"
./config.sh --unattended --ephemeral --disableupdate --replace \
  --url https://github.com/jai/trips-frontend --token "$token" \
  --name "borg-cube-03-android" --labels android,borg-cube-03 --work "$job_root/work"
./run.sh
