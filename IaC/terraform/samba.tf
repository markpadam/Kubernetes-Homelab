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
# The VM runs on the Multipass hypervisor (HVF on Apple Silicon), which gives it
# a real network interface on the Multipass subnet (192.168.64.0/24).
# This means the Minikube cluster can reach it if CoreDNS is configured to
# forward corp.internal queries to the VM's IP.
resource "null_resource" "samba_vm" {
  depends_on = [null_resource.multipass_check]

  triggers = {
    ad_domain         = var.ad_domain
    ad_domain_netbios = var.ad_domain_netbios
  }

  provisioner "local-exec" {
    command = <<-BASH
      set -euo pipefail

      echo "[samba] Removing any pre-existing samba-ad VM ..."
      multipass delete samba-ad --purge 2>/dev/null || true

      echo "[samba] Creating Multipass VM samba-ad ..."
      multipass launch 24.04 \
        --name samba-ad \
        --cpus "${var.samba_vm_cpus}" \
        --memory "${var.samba_vm_memory}" \
        --disk "${var.samba_vm_disk}" \
        --timeout 300

      echo "[samba] Waiting for network connectivity in VM ..."
      _mp_ping() {
        python3 -c "
import subprocess, sys
try:
    r = subprocess.run(
        ['multipass','exec','samba-ad','--','ping','-c','1','-W','2','8.8.8.8'],
        timeout=10, capture_output=True)
    sys.exit(r.returncode)
except Exception:
    sys.exit(1)
" 2>/dev/null
      }
      for i in $(seq 1 24); do
        if _mp_ping; then
          echo "[samba] Network ready after $i attempts"
          break
        fi
        sleep 5
      done
      _mp_ping || {
        echo ""
        echo "[samba] ERROR: samba-ad VM has no internet connectivity after 2 minutes."
        echo ""
        echo "  This is usually caused by Docker Desktop disrupting multipass NAT rules"
        echo "  when minikube starts (reconfigures network bridges on macOS)."
        echo ""
        echo "  Fix: reload the Multipass daemon, then re-run setup-lab.sh"
        echo ""
        echo "    sudo launchctl load /Library/LaunchDaemons/com.canonical.multipassd.plist"
        echo ""
        echo "  Verify the fix first:"
        echo "    multipass exec samba-ad -- ping -c 2 8.8.8.8"
        echo ""
        exit 1
      }

      echo "[samba] Forcing IPv4 for apt (Multipass VMs often lack IPv6 routing) ..."
      multipass exec samba-ad -- sudo bash -c \
        'echo "Acquire::ForceIPv4 \"true\";" > /etc/apt/apt.conf.d/99force-ipv4'

      echo "[samba] Installing packages ..."
      for i in $(seq 1 3); do
        multipass exec samba-ad -- sudo apt-get update -qq && break
        echo "[samba] apt-get update attempt $i failed, retrying in 10s..."
        sleep 10
      done
      multipass exec samba-ad -- sudo bash -c "
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
          samba winbind krb5-user attr dnsutils ldap-utils acl
      "

      echo "[samba] Stopping default samba services ..."
      multipass exec samba-ad -- sudo systemctl stop smbd nmbd winbind 2>/dev/null || true
      multipass exec samba-ad -- sudo systemctl disable smbd nmbd winbind 2>/dev/null || true

      echo "[samba] Removing default Samba config ..."
      multipass exec samba-ad -- sudo mv /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true

      echo "[samba] Provisioning domain ${var.ad_domain} (realm ${upper(var.ad_domain_netbios)}.${element(split(".", var.ad_domain), 1)}) ..."
      multipass exec samba-ad -- sudo samba-tool domain provision \
        --domain="${var.ad_domain_netbios}" \
        --realm="${var.ad_domain}" \
        --adminpass="${var.ad_admin_password}" \
        --dns-backend=SAMBA_INTERNAL \
        --server-role=dc \
        --use-rfc2307

      echo "[samba] Configuring DNS forwarder ..."
      multipass exec samba-ad -- sudo bash -c "
        grep -q 'dns forwarder' /etc/samba/smb.conf \
          || sed -i '/\[global\]/a \\tdns forwarder = 8.8.8.8' /etc/samba/smb.conf
      "

      echo "[samba] Configuring Kerberos ..."
      multipass exec samba-ad -- sudo bash -c "
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
      "

      echo "[samba] Starting samba-ad-dc service ..."
      multipass exec samba-ad -- sudo systemctl unmask samba-ad-dc
      multipass exec samba-ad -- sudo systemctl enable samba-ad-dc
      multipass exec samba-ad -- sudo systemctl start samba-ad-dc

      echo "[samba] Waiting for LDAP to be ready ..."
      for i in $(seq 1 30); do
        if python3 -c "
import subprocess, sys
try:
    r = subprocess.run(
        ['multipass','exec','samba-ad','--','sudo','samba-tool','domain','info','127.0.0.1'],
        timeout=15, capture_output=True)
    sys.exit(r.returncode)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
          echo "[samba] Domain ready after $i s"
          break
        fi
        sleep 2
      done

      echo "[samba] Creating lab OU and users ..."
      multipass exec samba-ad -- sudo samba-tool ou create \
        "OU=lab-users,DC=${lower(var.ad_domain_netbios)},DC=${element(split(".", var.ad_domain), length(split(".", var.ad_domain)) - 1)}" || true

      multipass exec samba-ad -- sudo samba-tool user create testuser1 \
        "${var.ad_test_user1_pass}" \
        --userou="OU=lab-users" \
        --given-name="Test" --surname="User One" 2>/dev/null || true

      multipass exec samba-ad -- sudo samba-tool user create testuser2 \
        "${var.ad_test_user2_pass}" \
        --userou="OU=lab-users" \
        --given-name="Test" --surname="User Two" 2>/dev/null || true

      multipass exec samba-ad -- sudo samba-tool group add lab-users 2>/dev/null || true
      multipass exec samba-ad -- sudo samba-tool group addmembers lab-users testuser1,testuser2 2>/dev/null || true

      SAMBA_IP=$(multipass info samba-ad --format json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['samba-ad']['ipv4'][0])")
      echo "[samba] VM ready — IP: $SAMBA_IP"
      echo "[samba] Domain: ${var.ad_domain}  Realm: ${upper(var.ad_domain)}"
      echo "[samba] Admin password: ${var.ad_admin_password}"
    BASH
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-BASH
      echo "[samba] Deleting samba-ad VM ..."
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
      multipass exec corp-client -- sudo apt-get install -y -qq \
        realmd sssd sssd-tools adcli-utils krb5-user ldap-utils \
        curl wget dnsutils net-tools

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
