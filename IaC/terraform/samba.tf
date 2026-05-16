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

      echo "[samba] Launching samba-ad VM (packages install during boot)..."
      multipass launch 24.04 \
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
resource "null_resource" "corp_client_vm" {
  depends_on = [time_sleep.samba_stabilise]

  triggers = {
    ad_domain = var.ad_domain
  }

  provisioner "local-exec" {
    command = <<-BASH
      set -euo pipefail

      # Get SambaAD VM IP
      SAMBA_IP=$(multipass info samba-ad --format json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['ipv4'][0])")
      echo "[client] SambaAD IP: $SAMBA_IP"

      echo "[client] Removing any pre-existing corp-client VM ..."
      multipass delete corp-client --purge 2>/dev/null || true

      echo "[client] Creating Multipass VM corp-client ..."
      multipass launch 24.04 \
        --name corp-client \
        --cpus "${var.client_vm_cpus}" \
        --memory "${var.client_vm_memory}" \
        --disk "${var.client_vm_disk}" \
        --timeout 300

      echo "[client] Installing packages ..."
      multipass exec corp-client -- sudo apt-get update -qq
      multipass exec corp-client -- sudo bash -c "
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
          realmd sssd sssd-tools adcli krb5-user ldap-utils \
          curl wget dnsutils net-tools
      "

      echo "[client] Configuring DNS to use SambaAD ..."
      multipass exec corp-client -- sudo systemctl disable --now systemd-resolved 2>/dev/null || true
      multipass exec corp-client -- sudo rm -f /etc/resolv.conf
      printf "nameserver $SAMBA_IP\nsearch ${var.ad_domain}\ndomain ${var.ad_domain}\n" \
        | multipass exec corp-client -- sudo tee /etc/resolv.conf > /dev/null
      multipass exec corp-client -- sudo chattr +i /etc/resolv.conf

      echo "[client] Verifying DNS to domain ..."
      for i in $(seq 1 15); do
        if python3 -c "
import subprocess, sys
try:
    r = subprocess.run(
        ['multipass','exec','corp-client','--','nslookup','${var.ad_domain}'],
        timeout=10, capture_output=True)
    sys.exit(r.returncode)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
          echo "[client] DNS OK after $i s"
          break
        fi
        sleep 2
      done

      echo "[client] Discovering realm ..."
      multipass exec corp-client -- sudo realm discover "${var.ad_domain}"

      echo "[client] Joining domain ${var.ad_domain} ..."
      multipass exec corp-client -- sudo bash -c "
        echo '${var.ad_admin_password}' | realm join ${var.ad_domain} -U Administrator --verbose
      "

      echo "[client] Enabling home directory creation on login ..."
      multipass exec corp-client -- sudo bash -c "
        pam-auth-update --enable mkhomedir --force
      "

      echo "[client] Configuring SSSD to allow short usernames ..."
      multipass exec corp-client -- sudo bash -c "
        sed -i 's/^use_fully_qualified_names.*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf || true
        systemctl restart sssd
      "

      echo "[client] Verifying domain join ..."
      for i in $(seq 1 10); do
        if python3 -c "
import subprocess, sys
try:
    r = subprocess.run(
        ['multipass','exec','corp-client','--','id','testuser1'],
        timeout=10, capture_output=True)
    sys.exit(r.returncode)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
          echo "[client] Domain join verified — testuser1 resolves"
          break
        fi
        sleep 3
      done

      # Add Mac-host entries so the client can reach cluster web apps
      # (Mac port-forwards are visible to VMs at the Multipass gateway IP)
      GATEWAY_IP=$(multipass exec corp-client -- ip route | grep default | awk '{print $3}')
      echo "[client] Gateway (Mac host) IP: $GATEWAY_IP"
      multipass exec corp-client -- sudo bash -c "
        cat >> /etc/hosts <<EOF

# AKS lab cluster services (via Mac host port-forwards on port 9980)
$GATEWAY_IP  taskflow.aks-lab.local
$GATEWAY_IP  grafana.aks-lab.local
$GATEWAY_IP  argocd.aks-lab.local
$GATEWAY_IP  blob-explorer.aks-lab.local
$GATEWAY_IP  oauth2-proxy.aks-lab.local
$GATEWAY_IP  dex.aks-lab.local
EOF
      "

      echo "[client] Setting up XFCE4 desktop and VNC..."
      bash "${path.module}/scripts/setup-corp-vnc.sh" "${var.vnc_password}"

      CLIENT_IP=$(multipass info corp-client --format json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['corp-client']['ipv4'][0])")
      echo "[client] corp-client ready — IP: $CLIENT_IP"
      echo "[client] Terminal: multipass shell corp-client"
      echo "[client] AD test:  multipass exec corp-client -- id testuser1"
    BASH
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-BASH
      echo "[client] Deleting corp-client VM ..."
      multipass delete corp-client --purge 2>/dev/null || true
      echo "[client] corp-client VM deleted"
    BASH
  }
}
