#!/bin/bash
set -euo pipefail

# ── Pin routing: use bridged interface (enp0s2) for internet, not Multipass NAT ──
# Multipass NAT (enp0s1, metric 100) beats bridged (enp0s2, metric 200) by default.
# Override via netplan so the preference survives reboots.
if ip link show enp0s2 &>/dev/null; then
  cat > /etc/netplan/60-bridged-routing.yaml << 'EOF'
network:
  version: 2
  ethernets:
    enp0s1:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false
        route-metric: 1000
EOF
  netplan apply 2>/dev/null || true
  # netplan apply triggers systemd-networkd DHCP re-negotiation which can
  # restore the NAT default route before UseRoutes=false takes effect.
  sleep 3
  ip route del default via 192.168.252.1 2>/dev/null || true
fi
echo "[samba] Active default routes: $(ip route show default)"

# ── Force apt to use IPv4 and configure retries ───────────────────────────
cat > /etc/apt/apt.conf.d/99force-ipv4 << 'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "5";
Acquire::http::Timeout "60";
Acquire::https::Timeout "60";
EOF

# ── Write systemd service files ────────────────────────────────────────────
# socat-based IPv4→IPv6 DNS proxy: Samba binds dns[master] to [::]:53 with
# IPV6_V6ONLY=1 (IPv6-only), so IPv4 DNS queries are refused.  These two
# services forward UDP/TCP IPv4:53 → ::1:53, making the domain reachable
# from IPv4-only clients such as the corp-client VM.
cat > /etc/systemd/system/samba-dns-proxy-udp.service << 'EOF'
[Unit]
Description=Samba DNS IPv4 UDP proxy
After=samba-ad-dc.service
Requires=samba-ad-dc.service

[Service]
Type=simple
ExecStart=/usr/bin/socat UDP4-LISTEN:53,reuseaddr,fork UDP6:[::1]:53
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/samba-dns-proxy-tcp.service << 'EOF'
[Unit]
Description=Samba DNS IPv4 TCP proxy
After=samba-ad-dc.service
Requires=samba-ad-dc.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP4-LISTEN:53,reuseaddr,fork TCP6:[::1]:53
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ── Install packages with retry ────────────────────────────────────────────
echo "[samba] Installing packages..."
_pkg_ok=false
for _attempt in 1 2 3 4 5; do
  # Re-delete NAT route each attempt in case systemd-networkd restored it.
  ip route del default via 192.168.252.1 2>/dev/null || true
  if apt-get update -qq; then
    if apt-get install -y --no-install-recommends \
        samba winbind attr dnsutils ldap-utils acl socat; then
      _pkg_ok=true
      break
    fi
  fi
  echo "[samba] Package install failed (attempt $_attempt/5) — retrying in 30s..."
  sleep 30
done
$_pkg_ok || { echo "[samba] ERROR: packages could not be installed after 5 attempts"; exit 1; }
echo "[samba] Packages installed"

echo "[samba] Stopping default Samba services..."
systemctl stop smbd nmbd winbind 2>/dev/null || true
systemctl disable smbd nmbd winbind 2>/dev/null || true

echo "[samba] Removing default Samba config..."
mv /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true

echo "[samba] Provisioning domain ${ad_domain} ..."
samba-tool domain provision \
  --domain="${ad_domain_netbios}" \
  --realm="${ad_domain}" \
  --adminpass="${ad_admin_password}" \
  --dns-backend=SAMBA_INTERNAL \
  --server-role=dc \
  --use-rfc2307

echo "[samba] Configuring DNS forwarder..."
grep -q 'dns forwarder' /etc/samba/smb.conf \
  || sed -i '/\[global\]/a \tdns forwarder = 8.8.8.8' /etc/samba/smb.conf

echo "[samba] Allowing plain LDAP binds (no TLS required)..."
grep -q 'ldap server require strong auth' /etc/samba/smb.conf \
  || sed -i 's/^\[global\]$/[global]\n\tldap server require strong auth = no/' /etc/samba/smb.conf

echo "[samba] Configuring Kerberos..."
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

echo "[samba] Starting samba-ad-dc..."
systemctl unmask samba-ad-dc
systemctl enable samba-ad-dc
systemctl start samba-ad-dc

echo "[samba] Waiting for LDAP to be ready..."
for i in $(seq 1 30); do
  samba-tool domain info 127.0.0.1 2>/dev/null \
    && echo "[samba] Domain ready after $i attempts" && break
  sleep 2
done

echo "[samba] Creating lab OU and users..."
samba-tool ou create "OU=lab-users,${dc_path}" 2>/dev/null || true
samba-tool user create testuser1 "${ad_test_user1_pass}" \
  --userou="OU=lab-users" \
  --given-name="Test" --surname="User One" 2>/dev/null || true
samba-tool user create testuser2 "${ad_test_user2_pass}" \
  --userou="OU=lab-users" \
  --given-name="Test" --surname="User Two" 2>/dev/null || true
samba-tool group add lab-users 2>/dev/null || true
samba-tool group addmembers lab-users testuser1,testuser2 2>/dev/null || true

echo "[samba] Starting DNS IPv4 proxy (socat)..."
systemctl daemon-reload
systemctl enable --now samba-dns-proxy-udp samba-dns-proxy-tcp

echo "[samba] Provisioning complete."
