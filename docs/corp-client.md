# Corp Client — Domain-Joined End User VM

## Overview

`corp-client` is a Multipass VM that simulates a corporate laptop joined to the `corp.internal` Active Directory domain. It provides an end-user perspective for testing authentication flows, AD group membership, Kerberos tickets, and access to cluster services.

| Property | Value |
|----------|-------|
| VM name | `corp-client` |
| Hypervisor | Multipass (ARM64 Ubuntu 24.04) |
| Domain | `corp.internal` |
| VM IP | Dynamic (Multipass DHCP) |
| DNS | Resolves via SambaAD VM IP |
| Auth stack | `realmd` + `SSSD` + `krb5` |

## Azure equivalent

| Lab | Azure |
|-----|-------|
| corp-client (Multipass VM) | Domain-joined corporate laptop |

## Domain join

The VM joins the domain at provisioning time using `realm join`:

```bash
echo 'AksLab!AdDev1' | realm join corp.internal -U Administrator
```

After joining, SSSD bridges Linux PAM/NSS to AD Kerberos/LDAP. AD users can log in as if they were local users.

## Network access to cluster services

The `/etc/hosts` file on `corp-client` points cluster service hostnames to `192.168.64.1` (the Mac host, which runs the NGINX ingress port-forward on port 9980):

```
192.168.64.1  taskflow.aks-lab.local
192.168.64.1  grafana.aks-lab.local
192.168.64.1  argocd.aks-lab.local
192.168.64.1  blob-explorer.aks-lab.local
192.168.64.1  dex.aks-lab.local
192.168.64.1  oauth2-proxy.aks-lab.local
```

## Desktop access (XFCE + VNC)

The VM runs an XFCE4 desktop over TigerVNC on display :1 (port 5901). Connect using macOS Screen Sharing — no port-forward needed, the Multipass subnet is directly reachable from the Mac:

```bash
# Get the VM IP
CLIENT_IP=$(multipass info corp-client --format json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['corp-client']['ipv4'][0])")

# Open macOS Screen Sharing
open vnc://${CLIENT_IP}:5901
# Password: AksLab1!  (set in var.vnc_password)
```

The VNC service runs as user `ubuntu` via a systemd unit (`vncserver@1`). To manage it from inside the VM:

```bash
multipass exec corp-client -- sudo systemctl status vncserver@1
multipass exec corp-client -- sudo systemctl restart vncserver@1
```

## Common commands

```bash
# Open a shell in the VM
multipass shell corp-client

# Check domain membership
realm list

# Resolve an AD user to a Linux UID
id testuser1@corp.internal

# Log in as an AD user
su - testuser1@corp.internal

# Get a Kerberos ticket
kinit testuser1@CORP.INTERNAL
klist
kdestroy

# Query AD via LDAP from the VM
ldapsearch -H ldap://<samba-ip>:389 \
  -x -D "Administrator@corp.internal" -w "AksLab!AdDev1" \
  -b "OU=lab-users,DC=corp,DC=internal" "(objectClass=person)" cn

# Access cluster web services (from inside the VM)
curl -v http://taskflow.aks-lab.local:9980

# Check SSSD status
systemctl status sssd

# Inspect SSSD config
cat /etc/sssd/sssd.conf
```

## Provisioning

Created by `terraform/local-mac/samba.tf` (`null_resource.corp_client_vm`) via `terraform apply`.  
Depends on `null_resource.samba_vm` — the domain controller must exist before the client can join.  
Destroyed by `terraform destroy` or `teardown-lab.sh`.

See also: [samba-ad.md](samba-ad.md), [auth-walkthrough.md](auth-walkthrough.md)
