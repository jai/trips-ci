#!/bin/zsh
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly base_vm="${TRIPS_LINUX_LIMA_BASE_VM:-trips-linux-runner-base}"
readonly base_cpus="${TRIPS_LINUX_LIMA_CPUS:-3}"
readonly base_memory_gib="${TRIPS_LINUX_LIMA_MEMORY_GIB:-8}"
readonly base_disk_gib="${TRIPS_LINUX_LIMA_DISK_GIB:-100}"
readonly guest_provisioner="${0:A:h}/provision-lima-runner-base.sh"

export LIMA_HOME="${LIMA_HOME:-/Users/jai/.lima}"

if /opt/homebrew/bin/limactl list "$base_vm" --json >/dev/null 2>&1; then
  print -u2 -- "Lima base ${base_vm} already exists; refusing to overwrite it."
  exit 1
fi

/opt/homebrew/bin/limactl start --tty=false \
  --name="$base_vm" \
  --arch=aarch64 \
  --vm-type=vz \
  --cpus="$base_cpus" \
  --memory="$base_memory_gib" \
  --disk="$base_disk_gib" \
  --plain \
  template:ubuntu-lts

/opt/homebrew/bin/limactl shell "$base_vm" -- \
  sudo bash -s < "$guest_provisioner"
/opt/homebrew/bin/limactl shell "$base_vm" -- \
  bash -lc 'set -e; test "$(uname -m)" = aarch64; test "$(nproc)" = 3; test "$(free -g | awk '\''/^Mem:/{print $2}'\'')" -ge 7; sudo docker info >/dev/null; docker compose version; node --version; npm --version; test -x /opt/actions-runner/bin/Runner.Listener'
/opt/homebrew/bin/limactl stop "$base_vm"
print -- "Prepared stopped Lima base ${base_vm}."
