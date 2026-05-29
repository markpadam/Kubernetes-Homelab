# ── Prerequisite check ────────────────────────────────────────────────────────
# Fail fast with a clear message if lima is not installed.
# Install: brew install lima socket_vmnet
# One-time setup: limactl sudoers | sudo tee /etc/sudoers.d/lima
resource "null_resource" "lima_check" {
  provisioner "local-exec" {
    command = <<-BASH
      if ! command -v limactl &>/dev/null; then
        echo ""
        echo "ERROR: limactl is not installed."
        echo "  Install with: brew install lima socket_vmnet"
        echo "  One-time:     limactl sudoers | sudo tee /etc/sudoers.d/lima"
        echo ""
        exit 1
      fi
      echo "[lima] $(limactl --version) — OK"
    BASH
  }
}

# ── SambaAD VM ────────────────────────────────────────────────────────────────
# Azure equivalent: an on-premises Active Directory Domain Controller.
# Samba 4 implements the full AD DS protocol stack — LDAP, Kerberos, DNS, SMB —
# making it wire-compatible with Windows AD clients and tools.
#
# Provisioned via limactl copy + shell: the provisioning script is rendered
# locally by Terraform, copied into the VM, and run via "limactl shell".

locals {
  # "corp.internal" → "DC=corp,DC=internal"
  samba_dc_path = join(",", [for part in split(".", var.ad_domain) : "DC=${part}"])
}

# Render the provisioning script with domain/credential variables.
resource "local_file" "samba_provision_script" {
  filename        = "/tmp/samba-provision.sh"
  file_permission = "0600"
  content = templatefile("${path.module}/scripts/samba-provision.sh.tpl", {
    ad_domain          = var.ad_domain
    ad_domain_netbios  = var.ad_domain_netbios
    ad_admin_password  = var.ad_admin_password
    ad_test_user1_pass = var.ad_test_user1_pass
    ad_test_user2_pass = var.ad_test_user2_pass
    dc_path            = local.samba_dc_path
  })
}

resource "null_resource" "samba_vm" {
  depends_on = [
    null_resource.lima_check,
    local_file.samba_provision_script,
  ]

  triggers = {
    ad_domain         = var.ad_domain
    ad_domain_netbios = var.ad_domain_netbios
    template_hash     = filemd5("${path.module}/scripts/samba-provision.sh.tpl")
  }

  provisioner "local-exec" {
    command = <<-BASH
      set -euo pipefail

      echo "[samba] Removing any pre-existing samba-ad VM..."
      limactl delete --force samba-ad 2>/dev/null || true

      # Use the Packer-built base image if it exists — packages are already
      # installed so the provisioning script only needs to run domain setup.
      # Fall back to plain Ubuntu 24.04 if the cache is missing.
      _SAMBA_BASE="$${HOME}/.lab-cache/images/samba-base.qcow2"
      if [[ -f "$_SAMBA_BASE" ]]; then
        _LAUNCH_IMAGE="file://$_SAMBA_BASE"
        echo "[samba] Using Packer base image — packages pre-installed ($${_SAMBA_BASE})"
      else
        _LAUNCH_IMAGE="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
        echo "[samba] No Packer cache found — packages will install via provisioning script"
        echo "[samba] Tip: run IaC/packer/build.sh samba to pre-build the image"
      fi

      # Convert Lima size format
      _mem_lima=$(echo "${var.samba_vm_memory}" | sed 's/G$/GiB/; s/M$/MiB/')
      _disk_lima=$(echo "${var.samba_vm_disk}"   | sed 's/G$/GiB/; s/M$/MiB/')

      echo "[samba] Generating Lima instance config..."
      cat > /tmp/lima-samba-ad.yaml << LIMAYAML
images:
  - location: "$_LAUNCH_IMAGE"
    arch: "x86_64"
vmType: "qemu"
os: "Linux"
cpus: ${var.samba_vm_cpus}
memory: "$_mem_lima"
disk: "$_disk_lima"
firmware:
  legacyBIOS: true
networks:
  - lima: "shared"
mounts: []
ssh:
  localPort: 0
  loadDotSSHPubKeys: false
LIMAYAML

      echo "[samba] Launching samba-ad Lima VM..."
      limactl start --name samba-ad --timeout 300s /tmp/lima-samba-ad.yaml

      echo "[samba] Waiting 10s for network interface to settle..."
      sleep 10

      # Configure a static IP on the Lima shared network interface so samba-ad
      # is always reachable at a predictable address. Match by driver so we
      # don't have to guess the exact interface name (enp0s1, eth0, ens3, …).
      if [[ -n "${var.samba_vm_static_ip}" ]]; then
        echo "[samba] Configuring static IP ${var.samba_vm_static_ip}/24 on virtio_net interface..."
        limactl shell samba-ad -- sudo bash -c "cat > /etc/netplan/61-static-lima.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    shared-net:
      match:
        driver: virtio_net
      dhcp4: false
      addresses: [${var.samba_vm_static_ip}/24]
      routes:
        - to: default
          via: ${var.vm_subnet_gateway}
      nameservers:
        addresses: [8.8.8.8, ${var.vm_subnet_gateway}]
NETPLAN
chmod 600 /etc/netplan/61-static-lima.yaml
netplan apply 2>/dev/null || true"
        echo "[samba] Static IP configured — samba-ad is at ${var.samba_vm_static_ip}"
        sleep 5
      fi

      echo "[samba] Verifying HTTP connectivity..."
      _vm_http_ok=false
      for _i in $(seq 1 12); do
        if limactl shell samba-ad -- \
            timeout 10 bash -c \
            'wget -q --spider --timeout=8 http://ports.ubuntu.com/ubuntu-ports/dists/noble/Release' \
            2>/dev/null; then
          _vm_http_ok=true
          break
        fi
        echo "[samba] HTTP not ready yet (attempt $_i/12) — waiting 10s..."
        sleep 10
      done
      if ! $_vm_http_ok; then
        echo "[samba] ERROR: HTTP unreachable — check Lima shared network (socket_vmnet)"
        exit 1
      fi
      echo "[samba] HTTP connectivity confirmed"

      echo "[samba] Copying provisioning script..."
      limactl copy /tmp/samba-provision.sh samba-ad:/tmp/samba-provision.sh

      echo "[samba] Running provisioning script (packages + domain setup)..."
      limactl shell samba-ad -- sudo bash /tmp/samba-provision.sh

      SAMBA_IP=$(limactl shell samba-ad -- ip addr show lima0 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1 || echo "")
      echo "[samba] VM ready — IP: $SAMBA_IP"
      echo "[samba] Domain: ${var.ad_domain}"
    BASH
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-BASH
      echo "[samba] Deleting samba-ad VM..."
      limactl delete --force samba-ad 2>/dev/null || true
      echo "[samba] samba-ad VM deleted"
    BASH
  }
}

# Brief pause to let the AD DC stabilise before the client attempts to join.
resource "time_sleep" "samba_stabilise" {
  depends_on      = [null_resource.samba_vm]
  create_duration = "10s"
}

# ── Corp Client VM ────────────────────────────────────────────────────────────
# Azure equivalent: a corporate-managed workstation or Azure AD–joined device.
# Provisioned via Lima with cloud-init user-data for domain join + XFCE4 + VNC.

# Render the template with all Terraform-known values. SAMBA_IP is a runtime
# value substituted by sed once the samba-ad VM IP is known.
resource "local_file" "corp_client_cloud_init_base" {
  filename        = "/tmp/corp-client-cloud-init.tpl"
  file_permission = "0600"
  content = templatefile("${path.module}/cloud-init/corp-client.tpl.yaml", {
    ad_domain         = var.ad_domain
    ad_admin_password = var.ad_admin_password
    vnc_password      = var.vnc_password
  })
}

resource "null_resource" "corp_client_vm" {
  depends_on = [
    time_sleep.samba_stabilise,
    local_file.corp_client_cloud_init_base,
  ]

  triggers = {
    ad_domain     = var.ad_domain
    template_hash = filemd5("${path.module}/cloud-init/corp-client.tpl.yaml")
  }

  provisioner "local-exec" {
    command = <<-BASH
      set -euo pipefail

      SAMBA_IP=$(limactl shell samba-ad -- ip addr show lima0 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1 || echo "")
      echo "[client] SambaAD IP: $SAMBA_IP"

      sed "s/SAMBA_IP_PLACEHOLDER/$SAMBA_IP/g" \
        /tmp/corp-client-cloud-init.tpl > /tmp/corp-client-cloud-init.yaml

      echo "[client] Removing any pre-existing corp-client VM..."
      limactl delete --force corp-client 2>/dev/null || true

      # Use the Packer-built base image if cached.
      _CLIENT_BASE="$${HOME}/.lab-cache/images/corp-client-base.qcow2"
      if [[ -f "$_CLIENT_BASE" ]]; then
        _LAUNCH_IMAGE="file://$_CLIENT_BASE"
        echo "[client] Using Packer base image — packages pre-installed ($${_CLIENT_BASE})"
      else
        _LAUNCH_IMAGE="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
        echo "[client] No Packer cache found — packages will install via cloud-init (~15-20 min)"
        echo "[client] Tip: run IaC/packer/build.sh corp-client to pre-build the image"
      fi

      _mem_lima=$(echo "${var.client_vm_memory}" | sed 's/G$/GiB/; s/M$/MiB/')
      _disk_lima=$(echo "${var.client_vm_disk}"   | sed 's/G$/GiB/; s/M$/MiB/')

      echo "[client] Generating Lima instance config..."
      cat > /tmp/lima-corp-client.yaml << LIMAYAML
images:
  - location: "$_LAUNCH_IMAGE"
    arch: "x86_64"
vmType: "qemu"
os: "Linux"
cpus: ${var.client_vm_cpus}
memory: "$_mem_lima"
disk: "$_disk_lima"
firmware:
  legacyBIOS: true
networks:
  - lima: "shared"
mounts: []
ssh:
  localPort: 0
  loadDotSSHPubKeys: false
LIMAYAML

      echo "[client] Launching corp-client Lima VM (cloud-init will run domain join + VNC setup)..."
      limactl start --name corp-client --timeout 900s /tmp/lima-corp-client.yaml

      echo "[client] Waiting 10s for network interface to settle..."
      sleep 10

      # Configure static IP if specified. Match by driver so interface naming
      # variations (enp0s1, eth0, ens3, …) don't break the config.
      if [[ -n "${var.corp_client_static_ip}" ]]; then
        echo "[client] Configuring static IP ${var.corp_client_static_ip}/24 on virtio_net interface..."
        timeout 30 limactl shell corp-client -- sudo bash -c "cat > /etc/netplan/61-static-lima.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    shared-net:
      match:
        driver: virtio_net
      dhcp4: false
      addresses: [${var.corp_client_static_ip}/24]
      routes:
        - to: default
          via: ${var.vm_subnet_gateway}
      nameservers:
        addresses: [8.8.8.8, ${var.vm_subnet_gateway}]
NETPLAN
chmod 600 /etc/netplan/61-static-lima.yaml
netplan apply 2>/dev/null || true" || true
        echo "[client] Static IP configured — corp-client is at ${var.corp_client_static_ip}"
      fi

      echo "[client] Copying rendered cloud-init user-data into VM..."
      limactl copy /tmp/corp-client-cloud-init.yaml corp-client:/tmp/user-data.yaml

      cat > /tmp/corp-client-init.py << 'PYEOF2'
#!/usr/bin/env python3
# Execute cloud-init user-data (write_files + runcmd) without the cloud-init daemon.
# Lima's CIDATA ISO takes precedence over a NoCloud seed, so we bypass cloud-init.
import yaml, subprocess, os, sys

with open('/tmp/user-data.yaml') as f:
    cfg = yaml.safe_load(f)

for wf in cfg.get('write_files', []):
    path = wf['path']
    content = wf.get('content', '')
    perm = wf.get('permissions', '0644')
    owner = wf.get('owner', 'root:root')
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'w') as fh:
        fh.write(content)
    try:
        os.chmod(path, int(str(perm), 8))
    except Exception:
        pass
    parts = str(owner).split(':', 1)
    u, g = parts[0], parts[1] if len(parts) > 1 else parts[0]
    subprocess.run(['chown', f'{u}:{g}', path], check=False)
    print(f'[provision] written: {path}', flush=True)

OPTIONAL = ('install-extras.sh', 'install-k8s-tools.sh')
for cmd in cfg.get('runcmd', []):
    display = (' '.join(str(c) for c in cmd) if isinstance(cmd, list) else str(cmd))[:100]
    optional = any(p in str(cmd) for p in OPTIONAL)
    print(f'[provision] running: {display}...', flush=True)
    if isinstance(cmd, list):
        r = subprocess.run([str(c) for c in cmd])
    else:
        r = subprocess.run(str(cmd), shell=True, executable='/bin/bash')
    if r.returncode != 0:
        if optional:
            print(f'[provision] WARNING: optional step failed (exit {r.returncode}) — skipping', flush=True)
        else:
            print(f'[provision] FAILED (exit {r.returncode})', flush=True)
            sys.exit(r.returncode)

print('[provision] All provisioning complete.', flush=True)
PYEOF2

      limactl copy /tmp/corp-client-init.py corp-client:/tmp/corp-client-init.py
      limactl shell corp-client -- sudo python3 /tmp/corp-client-init.py

      CLIENT_IP=$(limactl shell corp-client -- ip addr show lima0 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1 || echo "")
      echo "[client] corp-client ready — IP: $CLIENT_IP"
      echo "[client] VNC: open vnc://$CLIENT_IP:5901"
      echo "[client] Shell: limactl shell corp-client"
    BASH
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-BASH
      echo "[client] Deleting corp-client VM..."
      limactl delete --force corp-client 2>/dev/null || true
      echo "[client] corp-client VM deleted"
    BASH
  }
}
