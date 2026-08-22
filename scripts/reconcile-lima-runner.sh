#!/usr/bin/env bash
set -euo pipefail

repository="${1:?repository is required}"
slug="${2:?runner directory slug is required}"
runner_name="${3:?runner name is required}"
runner_labels="${4:-jai-ci}"
runner_version="${GITHUB_ACTIONS_RUNNER_VERSION:-2.336.0}"
runner_sha256="${GITHUB_ACTIONS_RUNNER_SHA256:-58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1}"
runner_root="/opt/actions-runner"
distribution="$runner_root/_distribution/$runner_version"
target="$runner_root/$slug"

IFS= read -r registration_token
if [[ -z "$registration_token" ]]; then
  echo "Registration token is required on stdin." >&2
  exit 1
fi
trap 'registration_token=' EXIT

existing_repository=""
existing_name=""
if [[ -f "$target/.runner" ]]; then
  existing_repository=$(jq -r '.gitHubUrl // ""' "$target/.runner")
  existing_name=$(jq -r '.agentName // ""' "$target/.runner")
fi

if [[ "$existing_repository" == "https://github.com/$repository" && "$existing_name" == "$runner_name" ]]; then
  service=$(basename "$(find /etc/systemd/system -maxdepth 1 -type f -name "actions.runner.*.${runner_name}.service" -print -quit)")
  if [[ -n "$service" ]]; then
    systemctl enable --now "$service"
    exit 0
  fi
fi

if [[ -x "$target/svc.sh" ]]; then
  "$target/svc.sh" stop >/dev/null 2>&1 || true
  "$target/svc.sh" uninstall >/dev/null 2>&1 || true
fi

install -d -m 0755 "$distribution" "$target"
if [[ ! -x "$distribution/bin/Runner.Listener" ]]; then
  archive="actions-runner-linux-arm64-${runner_version}.tar.gz"
  cache_dir="/var/cache/github-ci"
  install -d -m 0755 "$cache_dir"
  curl -fsSL "https://github.com/actions/runner/releases/download/v${runner_version}/${archive}" -o "$cache_dir/$archive"
  printf '%s  %s\n' "$runner_sha256" "$cache_dir/$archive" | sha256sum --check --status
  tar -xzf "$cache_dir/$archive" -C "$distribution"
fi

find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
rsync -a "$distribution/" "$target/"
chown -R jai:jai "$target"

printf '%s\n' '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' > "$target/.path"
chown jai:jai "$target/.path"

sudo -u jai "$target/config.sh" \
  --unattended \
  --disableupdate \
  --replace \
  --url "https://github.com/$repository" \
  --token "$registration_token" \
  --name "$runner_name" \
  --labels "$runner_labels" \
  --work _work

cd "$target"
./svc.sh install jai
./svc.sh start
