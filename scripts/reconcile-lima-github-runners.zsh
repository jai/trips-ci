#!/bin/zsh
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly app_id="${TRIPS_TART_GITHUB_APP_ID:-4452026}"
readonly installation_id="${TRIPS_TART_GITHUB_INSTALLATION_ID:-150444191}"
readonly repositories="${GITHUB_CI_LIMA_REPOSITORIES:-jai/trips-api,jai/trips-frontend,jai/trips-email-ingest-worker,jai/trips-infra,jai/trips,jai/trips-ci,jai/trips-fastlane,jai/openclaw-prompts}"
readonly private_key="${GITHUB_CI_GITHUB_APP_PRIVATE_KEY:-/Users/jai/.config/trips-tart-runner/github-app-private-key.pem}"
readonly lima_home="${LIMA_HOME:-/Volumes/mac-mini-external/lima}"
readonly lima_instance="${GITHUB_CI_LIMA_INSTANCE:-github-ci}"
readonly guest_reconciler="/usr/local/sbin/reconcile-lima-runner"

export LIMA_HOME="$lima_home"

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
  jwt=$(github_jwt)
  /usr/bin/curl -fsS -X POST \
    -H "Authorization: Bearer $jwt" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/app/installations/${installation_id}/access_tokens" |
    /usr/bin/jq -er .token
}

if [[ ! -s "$private_key" ]]; then
  print -u2 -- "GitHub App private key is missing: $private_key"
  exit 1
fi

token=$(installation_token)
trap 'token=' EXIT

for repository in ${(s:,:)repositories}; do
  metadata=$(/usr/bin/curl -fsS \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}")
  if [[ "$(printf '%s' "$metadata" | /usr/bin/jq -r .private)" != "true" ]]; then
    print -u2 -- "Skipping non-private repository ${repository}; persistent self-hosted runners are private-repository only."
    continue
  fi

  slug="${repository#*/}"
  slug="${slug:l}"
  runner_name="jais-mac-mini-lima-${slug}"
  registration_token=$(/usr/bin/curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${repository}/actions/runners/registration-token" |
    /usr/bin/jq -er .token)

  printf '%s\n' "$registration_token" |
    /opt/homebrew/bin/limactl shell "$lima_instance" -- \
      sudo "$guest_reconciler" "$repository" "$slug" "$runner_name" jai-ci
  registration_token=''
done
