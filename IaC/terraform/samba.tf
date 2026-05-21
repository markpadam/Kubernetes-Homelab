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
# Provisioned via cloud-init: packages install in parallel with VM boot,
# and a single embedded shell script handles all Samba configuration.
# This eliminates ~15 sequential multipass exec round-trips and halves
# provisioning time vs. the old approach.

locals {
  # "corp.internal" → "DC=corp,DC=internal"
  samba_dc_path = join(",", [for part in split(".", var.ad_domain) : "DC=${part}"])
}

# Render the cloud-init template with domain/credential variables and write
# it to a temp file. The file path (non-sensitive) is passed to multipass
# launch; the sensitive values never appear in the null_resource command
# string, so Terraform does not suppress provisioner output.
resource "local_file" "samba_cloud_init" {
  filename        = "/tmp/samba-ad-cloud-init.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/cloud-init/samba-ad.tpl.yaml", {
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
    local_file.samba_cloud_init,
  ]

  triggers = {
    ad_domain         = var.ad_domain
    ad_domain_netbios = var.ad_domain_netbios
    template_hash     = filemd5("${path.module}/cloud-init/samba-ad.tpl.yaml")
  }

  provisioner "local-exec" {
    command = <<-BASH
      set -euo pipefail

      echo "[samba] Removing any pre-existing samba-ad VM..."
      multipass delete samba-ad --purge 2>/dev/null || true

      # Use the Packer-built base image if it exists — packages are already
      # installed so cloud-init only needs to run the domain provisioning step.
      # Fall back to plain Ubuntu 24.04 if the cache is missing.
      _SAMBA_BASE="${HOME}/.lab-cache/images/samba-base.tar.gz"
      if [[ -f "$_SAMBA_BASE" ]]; then
        _LAUNCH_IMAGE="file://$_SAMBA_BASE"
        echo "[samba] Using Packer base image — packages pre-installed (${_SAMBA_BASE})"
      else
        _LAUNCH_IMAGE="24.04"
        echo "[samba] No Packer cache found — packages will install via cloud-init"
        echo "[samba] Tip: run IaC/packer/build.sh samba to pre-build the image"
      fi

      echo "[samba] Launching samba-ad VM..."
      multipass launch "$_LAUNCH_IMAGE" \
        --name samba-ad \
        --cpus "${var.samba_vm_cpus}" \
        --memory "${var.samba_vm_memory}" \
        --disk "${var.samba_vm_disk}" \
        --cloud-init /tmp/samba-ad-cloud-init.yaml \
        --timeout 300

      echo "[samba] Streaming cloud-init log..."
      multipass exec samba-ad -- bash -c '
        until [ -f /var/log/cloud-init-output.log ]; do sleep 1; done
        exec tail -F /var/log/cloud-init-output.log
      ' &
      _TAIL_PID=$!

      echo "[samba] Waiting for cloud-init to complete (packages + domain provision)..."
      _CI_RC=0
      python3 -c "
import subprocess, sys
r = subprocess.run(
    ['multipass', 'exec', 'samba-ad', '--', 'cloud-init', 'status', '--wait'],
    timeout=600)
sys.exit(r.returncode)
" || _CI_RC=$?

      kill $_TAIL_PID 2>/dev/null || true
      wait $_TAIL_PID 2>/dev/null || true

      # cloud-init exit codes: 0=done, 1=error, 2=recoverable_error (warnings only).
      # Treat 0 and 2 as success — 2 means non-fatal warnings, provisioning still ran.
      if [[ $_CI_RC -eq 1 ]]; then
        echo "[samba] ERROR: cloud-init hard failure (rc=$_CI_RC) — last 60 lines of log:"
        multipass exec samba-ad -- sudo tail -60 /var/log/cloud-init-output.log 2>/dev/null || true
        exit 1
      fi

      # Belt-and-suspenders: verify the provisioning script reached completion.
      if ! multipass exec samba-ad -- grep -q '\[samba\] Provisioning complete\.' \
          /var/log/cloud-init-output.log 2>/dev/null; then
        echo "[samba] ERROR: samba-provision.sh did not reach completion — last 30 lines:"
        multipass exec samba-ad -- sudo tail -30 /var/log/cloud-init-output.log 2>/dev/null || true
        exit 1
      fi

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
      _CLIENT_BASE="${HOME}/.lab-cache/images/corp-client-base.tar.gz"
      if [[ -f "$_CLIENT_BASE" ]]; then
        _LAUNCH_IMAGE="file://$_CLIENT_BASE"
        echo "[client] Using Packer base image — packages pre-installed (${_CLIENT_BASE})"
      else
        _LAUNCH_IMAGE="24.04"
        echo "[client] No Packer cache found — packages will install via cloud-init (~15-20 min)"
        echo "[client] Tip: run IaC/packer/build.sh corp-client to pre-build the image"
      fi

      echo "[client] Launching corp-client VM..."
      multipass launch "$_LAUNCH_IMAGE" \
        --name corp-client \
        --cpus "${var.client_vm_cpus}" \
        --memory "${var.client_vm_memory}" \
        --disk "${var.client_vm_disk}" \
        --cloud-init /tmp/corp-client-cloud-init.yaml \
        --timeout 300

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

      if [[ $_CI_RC -eq 1 ]]; then
        echo "[client] ERROR: cloud-init hard failure (rc=$_CI_RC) — last 60 lines:"
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
