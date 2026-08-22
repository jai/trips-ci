#!/usr/bin/env bash
set -euo pipefail

node_release_line="${GITHUB_CI_NODE_RELEASE_LINE:-24}"
cache_dir="/var/cache/github-ci"
node_root="/usr/local/lib/nodejs"

install -d -m 0755 "$cache_dir" "$node_root"

checksums="$cache_dir/node-v${node_release_line}-SHASUMS256.txt"
curl -fsSL "https://nodejs.org/dist/latest-v${node_release_line}.x/SHASUMS256.txt" -o "$checksums"
archive=$(awk '$2 ~ /linux-arm64\.tar\.xz$/ {print $2; exit}' "$checksums")
expected_sha=$(awk -v archive="$archive" '$2 == archive {print $1; exit}' "$checksums")

if [[ -z "$archive" || -z "$expected_sha" ]]; then
  echo "Unable to resolve the latest Node ${node_release_line} ARM64 archive." >&2
  exit 1
fi

version="${archive#node-v}"
version="${version%-linux-arm64.tar.xz}"
install_dir="$node_root/node-v${version}-linux-arm64"

if [[ ! -x "$install_dir/bin/node" ]]; then
  curl -fsSL "https://nodejs.org/dist/v${version}/${archive}" -o "$cache_dir/$archive"
  printf '%s  %s\n' "$expected_sha" "$cache_dir/$archive" | sha256sum --check --status
  tar -xJf "$cache_dir/$archive" -C "$node_root"
fi

for executable in node npm npx corepack; do
  if [[ -x "$install_dir/bin/$executable" ]]; then
    ln -sfn "$install_dir/bin/$executable" "/usr/local/bin/$executable"
  fi
done

if [[ -f /home/jai.guest/.npmrc ]]; then
  sed -i '/^[[:space:]]*prefix[[:space:]]*=/d' /home/jai.guest/.npmrc
  chown jai:jai /home/jai.guest/.npmrc
fi

if ! id -nG jai | tr ' ' '\n' | grep -qx docker; then
  usermod -aG docker jai
fi

/usr/local/bin/node --version
/usr/local/bin/npm --version
docker info --format 'Docker {{.ServerVersion}} using {{.Driver}} at {{.DockerRootDir}}'
