# Corp Client — Domain-Joined End User VM

## Overview

`corp-client` is a Lima VM that simulates a corporate laptop joined to the `corp.internal` Active Directory domain. It provides an end-user perspective for testing authentication flows, AD group membership, Kerberos tickets, and access to cluster services.

| Property | Value |
|----------|-------|
| VM name | `corp-client` |
| Hypervisor | Lima (ARM64 Ubuntu 24.04) |
| Domain | `corp.internal` |
| VM IP | Dynamic (Lima DHCP) |
| DNS | Resolves via SambaAD VM IP |
| Auth stack | `realmd` + `SSSD` + `krb5` |

## Azure equivalent

| Lab | Azure |
|-----|-------|
| corp-client (Lima VM) | Domain-joined corporate laptop |

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

The VM runs an XFCE4 desktop over TigerVNC on display :1 (port 5901). Connect using macOS Screen Sharing — no port-forward needed, the Lima subnet is directly reachable from the Mac:

```bash
# Get the VM IP
CLIENT_IP=$(limactl shell corp-client -- ip -4 addr show lima0 \
  | awk '/inet /{print $2}' | cut -d/ -f1)

# Open macOS Screen Sharing
open vnc://${CLIENT_IP}:5901
# Password: AksLab1!  (set in var.vnc_password)
```

The VNC service runs as user `ubuntu` via a systemd unit (`vncserver@1`). To manage it from inside the VM:

```bash
limactl shell corp-client -- sudo systemctl status vncserver@1
limactl shell corp-client -- sudo systemctl restart vncserver@1
```

## Common commands

```bash
# Open a shell in the VM
limactl shell corp-client

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
curl -v https://taskflow.aks-lab.local:9444

# Check SSSD status
systemctl status sssd

# Inspect SSSD config
cat /etc/sssd/sssd.conf
```

## Pre-built base image (Packer)

The corp-client VM has the heaviest provisioning footprint in the lab — XFCE4, Firefox, Sublime Text, Azure CLI, and the full Kubernetes toolchain all install on first provision (~20 min). A Packer-built base image bakes all of this in, so Terraform only needs to run the domain join and VNC configuration at apply time (under a minute).

```bash
IaC/packer/build.sh corp-client
```

The image is saved to `~/.lab-cache/images/corp-client-base.tar.gz` and detected automatically by Terraform on the next apply.

### Tools pre-installed in the base image

| Category | Tools |
|----------|-------|
| Kubernetes | `kubectl`, `helm`, `k9s`, `kubectx`, `kubens` |
| GitOps | `flux`, `argocd`, `argo` (Workflows CLI) |
| HashiCorp | `vault` |
| Azure | `az` (Azure CLI + azure-devops extension), `azcopy` |
| Observability | `stern` (multi-pod log tailing) |
| Utilities | `jq`, `yq` |
| Desktop | XFCE4, TigerVNC, Firefox, Sublime Text |

The `kubeconfig` is **not** set up in the base image — it needs the Mac host IP at runtime. After provisioning:

```bash
# Copy your kubeconfig in and rewrite the server address to the Lima gateway
limactl copy ~/.kube/config corp-client:/home/ubuntu/.kube/config
limactl shell corp-client -- sed -i 's|https://127.0.0.1|https://192.168.105.1|g' /home/ubuntu/.kube/config
```

## Provisioning

Created by `IaC/terraform/samba.tf` (`null_resource.corp_client_vm`) via `terraform apply`.  
Depends on `null_resource.samba_vm` — the domain controller must exist before the client can join.  
Destroyed by `terraform destroy` or `teardown-lab.sh`.

See also: [samba-ad.md](../services/samba-ad.md), [auth-walkthrough.md](../guides/auth-walkthrough.md), [packer.md](../iac/packer.md)
