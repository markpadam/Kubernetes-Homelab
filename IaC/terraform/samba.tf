# ── Prerequisite check ────────────────────────────────────────────────────────
# Fail fast with a clear message if multipass is not installed.
# Install with: brew install multipass
resource "null_resource" "multipass_check" {
  provisioner "local-exec" {
    command = <<-BASH
      if ! command -v multipass &>/dev/null; then
        echo ""
        echo "ERROR: multipass is not installed."
        echo "  Install with: brew install multipass"
        echo ""
        exit 1
      fi
      echo "[multipass] $(multipass version | head -1) — OK"
    BASH
  }
}

# ── SambaAD VM ────────────────────────────────────────────────────────────────
# Azure equivalent: an on-premises Active Directory Domain Controller.
# Samba 4 implements the full AD DS protocol stack — LDAP, Kerberos, DNS, SMB —
# making it wire-compatible with Windows AD clients and tools.
#
# Provisioned via multipass transfer + exec: the provisioning script is rendered
# locally by Terraform, transferred into the VM, and run via "multipass exec".
# This bypasses cloud-init entirely, avoiding cloud-init 25.x schema validation
# failures that silently skip runcmd when the YAML round-trip converts quoted
# octal permission strings to integers.

locals {
  # "corp.internal" → "DC=corp,DC=internal"
  samba_dc_path = join(",", [for part in split(".", var.ad_domain) : "DC=${part}"])
}

# Render the provisioning script with domain/credential variables.
# Written to a temp file and transferred into the VM via multipass transfer.
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
    null_resource.multipass_check,
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
      multipass delete samba-ad --purge 2>/dev/null || true

      # Use the Packer-built base image if it exists — packages are already
      # installed so the provisioning script only needs to run domain setup.
      # Fall back to plain Ubuntu 24.04 if the cache is missing.
      _SAMBA_BASE="$${HOME}/.lab-cache/images/samba-base.tar.gz"
      if [[ -f "$_SAMBA_BASE" ]]; then
        _LAUNCH_IMAGE="file://$_SAMBA_BASE"
        echo "[samba] Using Packer base image — packages pre-installed ($${_SAMBA_BASE})"
      else
        _LAUNCH_IMAGE="24.04"
        echo "[samba] No Packer cache found — packages will install via provisioning script"
        echo "[samba] Tip: run IaC/packer/build.sh samba to pre-build the image"
      fi

      echo "[samba] Launching samba-ad VM (bridged to en0 for direct internet)..."
      multipass launch "$_LAUNCH_IMAGE" \
        --name samba-ad \
        --cpus "${var.samba_vm_cpus}" \
        --memory "${var.samba_vm_memory}" \
        --disk "${var.samba_vm_disk}" \
        --network en0 \
        --timeout 300

      echo "[samba] Waiting 15s for bridged interface DHCP..."
      sleep 15

      # The Multipass NAT interface (enp0s1) gets metric 100 and the bridged
      # interface (enp0s2) gets metric 200, so Linux prefers the broken NAT
      # default route. Remove it so internet traffic falls through to the
      # bridged default route. The connected 192.168.252.0/24 route stays,
      # keeping multipass exec working.
      echo "[samba] Removing Multipass NAT default route to force traffic via bridged interface..."
      multipass exec samba-ad -- sudo ip route del default via 192.168.252.1 2>/dev/null || true

      # Assign static IP to the bridged interface (enp0s2) so samba-ad is always
      # reachable at a predictable address within 172.16.2.0/24.
      if [[ -n "${var.samba_vm_static_ip}" ]]; then
        echo "[samba] Configuring static IP ${var.samba_vm_static_ip}/24 on enp0s2..."
        multipass exec samba-ad -- sudo bash -c "cat > /etc/netplan/61-static-bridge.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    enp0s2:
      addresses: [${var.samba_vm_static_ip}/24]
      routes:
        - to: default
          via: ${var.vm_subnet_gateway}
      nameservers:
        addresses: [${var.vm_subnet_gateway}, 8.8.8.8]
NETPLAN
chmod 600 /etc/netplan/61-static-bridge.yaml
netplan apply 2>/dev/null || true"
        echo "[samba] Static IP configured — samba-ad is at ${var.samba_vm_static_ip}"
      fi

      echo "[samba] Verifying HTTP connectivity via bridged interface..."
      _vm_http_ok=false
      for _i in $(seq 1 12); do
        if multipass exec samba-ad -- \
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
        echo "[samba] ERROR: HTTP unreachable after bridged network — check en0 DHCP"
        exit 1
      fi
      echo "[samba] HTTP connectivity confirmed"

      echo "[samba] Transferring provisioning script..."
      multipass transfer /tmp/samba-provision.sh samba-ad:/tmp/samba-provision.sh

      echo "[samba] Running provisioning script (packages + domain setup)..."
      multipass exec samba-ad -- sudo bash /tmp/samba-provision.sh

      SAMBA_IP=$(multipass info samba-ad --format json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['ipv4'][0])")
      echo "[samba] VM ready — IP: $SAMBA_IP"
      echo "[samba] Domain: ${var.ad_domain}"
    BASH
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-BASH
      echo "[samba] Deleting samba-ad VM..."
      multipass delete samba-ad --purge 2>/dev/null || true
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
# On-prem this would be a Windows or Linux machine domain-joined via Group Policy
# or realmd. Here we use realmd + SSSD to join the Ubuntu VM to the Samba domain,
# giving us AD user login, Kerberos tickets, and LDAP integration out of the box.
#
# Provisioned via cloud-init: packages (including XFCE4 + VNC) install during
# boot; a single embedded script handles domain join and desktop setup.
# SAMBA_IP is obtained at runtime from multipass info and substituted into the
# rendered template by sed before launching the VM.

# Render the template with all Terraform-known values. SAMBA_IP is a runtime
# value (the actual samba-ad VM IP); a placeholder is used here and swapped
# out by sed in the provisioner once multipass info gives us the real IP.
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

      SAMBA_IP=$(multipass info samba-ad --format json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['ipv4'][0])")
      echo "[client] SambaAD IP: $SAMBA_IP"

      sed "s/SAMBA_IP_PLACEHOLDER/$SAMBA_IP/g" \
        /tmp/corp-client-cloud-init.tpl > /tmp/corp-client-cloud-init.yaml

      echo "[client] Removing any pre-existing corp-client VM..."
      multipass delete corp-client --purge 2>/dev/null || true

      # Use the Packer-built base image if cached — saves 15-20 min on first run
      # (XFCE4, Firefox, k8s tools, Azure CLI are all pre-installed).
      _CLIENT_BASE="$${HOME}/.lab-cache/images/corp-client-base.tar.gz"
      if [[ -f "$_CLIENT_BASE" ]]; then
        _LAUNCH_IMAGE="file://$_CLIENT_BASE"
        echo "[client] Using Packer base image — packages pre-installed ($${_CLIENT_BASE})"
      else
        _LAUNCH_IMAGE="24.04"
        echo "[client] No Packer cache found — packages will install via cloud-init (~15-20 min)"
        echo "[client] Tip: run IaC/packer/build.sh corp-client to pre-build the image"
      fi

      echo "[client] Launching corp-client VM (bridged to en0 for direct internet)..."
      multipass launch "$_LAUNCH_IMAGE" \
        --name corp-client \
        --cpus "${var.client_vm_cpus}" \
        --memory "${var.client_vm_memory}" \
        --disk "${var.client_vm_disk}" \
        --network en0 \
        --cloud-init /tmp/corp-client-cloud-init.yaml \
        --timeout 900

      echo "[client] Waiting 15s for bridged interface DHCP..."
      sleep 15

      echo "[client] Removing Multipass NAT default route (prefer bridged interface)..."
      timeout 30 multipass exec corp-client -- sudo ip route del default via 192.168.252.1 2>/dev/null || true

      # Assign static IP to the bridged interface so corp-client is reachable at a
      # predictable address within 172.16.2.0/24.
      if [[ -n "${var.corp_client_static_ip}" ]]; then
        echo "[client] Configuring static IP ${var.corp_client_static_ip}/24 on enp0s2..."
        timeout 30 multipass exec corp-client -- sudo bash -c "cat > /etc/netplan/61-static-bridge.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    enp0s2:
      addresses: [${var.corp_client_static_ip}/24]
      routes:
        - to: default
          via: ${var.vm_subnet_gateway}
      nameservers:
        addresses: [${var.vm_subnet_gateway}, 8.8.8.8]
NETPLAN
chmod 600 /etc/netplan/61-static-bridge.yaml
netplan apply 2>/dev/null || true" || true
        echo "[client] Static IP configured — corp-client is at ${var.corp_client_static_ip}"
      fi

      echo "[client] Streaming cloud-init log..."
      multipass exec corp-client -- bash -c '
        until [ -f /var/log/cloud-init-output.log ]; do sleep 1; done
        exec tail -F /var/log/cloud-init-output.log
      ' &
      _TAIL_PID=$!

      echo "[client] Waiting for cloud-init to complete (domain join + VNC setup)..."
      _CI_RC=0
      python3 -c "
import subprocess, sys
r = subprocess.run(
    ['multipass', 'exec', 'corp-client', '--', 'cloud-init', 'status', '--wait'],
    timeout=900)
sys.exit(r.returncode)
" || _CI_RC=$?

      kill $_TAIL_PID 2>/dev/null || true
      wait $_TAIL_PID 2>/dev/null || true

      if [[ $_CI_RC -ne 0 ]]; then
        echo "[client] ERROR: cloud-init finished with rc=$_CI_RC — last 60 lines:"
        multipass exec corp-client -- sudo tail -60 /var/log/cloud-init-output.log 2>/dev/null || true
        exit 1
      fi

      if ! multipass exec corp-client -- grep -q '\[client\] Client provisioning complete\.' \
          /var/log/cloud-init-output.log 2>/dev/null; then
        echo "[client] ERROR: client-setup.sh did not reach completion — last 30 lines:"
        multipass exec corp-client -- sudo tail -30 /var/log/cloud-init-output.log 2>/dev/null || true
        exit 1
      fi

      CLIENT_IP=$(multipass info corp-client --format json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['corp-client']['ipv4'][0])")
      echo "[client] corp-client ready — IP: $CLIENT_IP"
      echo "[client] VNC: open vnc://$CLIENT_IP:5901"
      echo "[client] Shell: multipass shell corp-client"
    BASH
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-BASH
      echo "[client] Deleting corp-client VM..."
      multipass delete corp-client --purge 2>/dev/null || true
      echo "[client] corp-client VM deleted"
    BASH
  }
}
