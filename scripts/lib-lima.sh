#!/usr/bin/env bash
# lib-lima.sh — Lima VM helpers (replaces Multipass)
# Sourced automatically via lib-common.sh.
# Requires: lima (brew install lima), socket_vmnet (brew install socket_vmnet)
#   After install: limactl sudoers | sudo tee /etc/sudoers.d/lima

# Resolve a VM image reference to a URL.
# Accepts Multipass-style aliases (24.04) or file:// paths.
_lima_image_url() {
  case "$1" in
    24.04|ubuntu:24.04) echo "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img" ;;
    22.04|ubuntu:22.04) echo "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img" ;;
    *) echo "$1" ;;
  esac
}

# Convert Multipass size string (2G, 1500M) to Lima format (2GiB, 1500MiB).
_lima_size() { echo "$1" | sed 's/G$/GiB/; s/M$/MiB/'; }

# Get the primary routable IPv4 of a Lima VM (empty if not running or no IP yet).
_lima_ip() {
  local name="$1"
  limactl list --format json 2>/dev/null \
    | python3 -c "
import json, sys
vms = json.load(sys.stdin)
vm = next((v for v in vms if v['name'] == '$name'), {})
nets = vm.get('network') or vm.get('networks') or []
ip = next((n.get('localIPV4','') for n in nets
           if n.get('localIPV4') and not n.get('localIPV4','').startswith('127.')), '')
print(ip)
" 2>/dev/null || echo ""
}

# Get the status of a Lima VM: Running, Stopped, or Deleted.
_lima_status() {
  local name="$1"
  limactl list --format json 2>/dev/null \
    | python3 -c "
import json, sys
vms = json.load(sys.stdin)
vm = next((v for v in vms if v['name'] == '$name'), None)
print(vm['status'] if vm else 'Deleted')
" 2>/dev/null || echo "Deleted"
}

# Print running VM names (one per line), excluding an optional name.
_lima_list_running_except() {
  local exclude="${1:-__none__}"
  limactl list --format json 2>/dev/null \
    | python3 -c "
import json, sys
for v in json.load(sys.stdin):
    if v.get('status') == 'Running' and v.get('name') != '$exclude':
        print(v['name'])
" 2>/dev/null || true
}

# Run a command inside a Lima VM as the default user (ubuntu).
# Usage: _lima_exec <name> -- <cmd> [args...]
_lima_exec() {
  local name="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  limactl shell "$name" -- "$@"
}

# Copy a local file into a Lima VM.
# Usage: _lima_copy /local/src vm-name:/remote/dest
_lima_copy() {
  local src="$1"
  local dest_spec="$2"
  local vm_name="${dest_spec%%:*}"
  local vm_path="${dest_spec#*:}"
  limactl copy "$src" "${vm_name}:${vm_path}"
}

_lima_stop()   { limactl stop "$1" 2>/dev/null || true; }
_lima_start()  { limactl start "$1"; }
_lima_delete() { limactl delete --force "$1" 2>/dev/null || true; }

# Create and start a Lima VM using the shared vmnet network.
# Usage: _lima_create <name> <image> <cpus> <mem> <disk> [--cloud-init <file>] [--timeout <secs>]
_lima_create() {
  local name="$1" image="$2" cpus="$3" mem="$4" disk="$5"
  shift 5
  local cloud_init="" timeout=300
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cloud-init) cloud_init="$2"; shift 2 ;;
      --timeout)    timeout="$2";    shift 2 ;;
      *) shift ;;
    esac
  done

  local img_url mem_lima disk_lima yaml
  img_url=$(_lima_image_url "$image")
  mem_lima=$(_lima_size "$mem")
  disk_lima=$(_lima_size "$disk")
  yaml="/tmp/lima-${name}.yaml"

  cat > "$yaml" << LIMAYAML
images:
  - location: "$img_url"
    arch: "x86_64"
vmType: "qemu"
os: "Linux"
cpus: $cpus
memory: "$mem_lima"
disk: "$disk_lima"
networks:
  - lima: "shared"
mounts: []
ssh:
  localPort: 0
  loadDotSSHPubKeys: false
LIMAYAML

  if [[ -n "$cloud_init" ]]; then
    printf 'userData:\n  location: "file://%s"\n' "$cloud_init" >> "$yaml"
  fi

  limactl start --name "$name" --timeout "${timeout}s" "$yaml"
}
