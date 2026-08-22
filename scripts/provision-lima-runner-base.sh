#!/usr/bin/env bash
set -euo pipefail

runner_version="${GITHUB_ACTIONS_RUNNER_VERSION:-2.336.0}"
runner_sha256="${GITHUB_ACTIONS_RUNNER_SHA256:-58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1}"
node_release_line="${GITHUB_CI_NODE_RELEASE_LINE:-24}"
cache_dir="/var/cache/github-ci"
runner_root="/opt/actions-runner"
node_root="/usr/local/lib/nodejs"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential ca-certificates curl docker.io gh git git-lfs jq rsync shellcheck unzip xz-utils
apt-get clean
rm -rf /var/lib/apt/lists/*

systemctl enable --now docker
if ! id -nG jai | tr ' ' '\n' | grep -qx docker; then
  usermod -aG docker jai
fi

install -d -m 0755 "$cache_dir" "$runner_root" "$node_root"
runner_archive="actions-runner-linux-arm64-${runner_version}.tar.gz"
curl -fsSL \
  "https://github.com/actions/runner/releases/download/v${runner_version}/${runner_archive}" \
  -o "$cache_dir/$runner_archive"
printf '%s  %s\n' "$runner_sha256" "$cache_dir/$runner_archive" |
  sha256sum --check --status
find "$runner_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
tar -xzf "$cache_dir/$runner_archive" -C "$runner_root"
chown -R jai:jai "$runner_root"

checksums="$cache_dir/node-v${node_release_line}-SHASUMS256.txt"
curl -fsSL "https://nodejs.org/dist/latest-v${node_release_line}.x/SHASUMS256.txt" -o "$checksums"
node_archive=$(awk '$2 ~ /linux-arm64\.tar\.xz$/ {print $2; exit}' "$checksums")
node_sha256=$(awk -v archive="$node_archive" '$2 == archive {print $1; exit}' "$checksums")
if [[ -z "$node_archive" || -z "$node_sha256" ]]; then
  echo "Unable to resolve the latest Node ${node_release_line} ARM64 archive." >&2
  exit 1
fi
node_version="${node_archive#node-v}"
node_version="${node_version%-linux-arm64.tar.xz}"
node_install="$node_root/node-v${node_version}-linux-arm64"
curl -fsSL "https://nodejs.org/dist/v${node_version}/${node_archive}" -o "$cache_dir/$node_archive"
printf '%s  %s\n' "$node_sha256" "$cache_dir/$node_archive" |
  sha256sum --check --status
tar -xJf "$cache_dir/$node_archive" -C "$node_root"
for executable in node npm npx corepack; do
  ln -sfn "$node_install/bin/$executable" "/usr/local/bin/$executable"
done

runner_home=$(getent passwd jai | cut -d: -f6)
install -d -m 0755 "$runner_home/.cache" "$runner_home/.npm"
chown -R jai:jai "$runner_home/.cache" "$runner_home/.npm"
docker info --format 'Docker {{.ServerVersion}} using {{.Driver}} at {{.DockerRootDir}}'
/usr/bin/gh --version
/usr/local/bin/node --version
/usr/local/bin/npm --version
