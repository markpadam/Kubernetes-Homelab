# SambaAD — Active Directory Domain Controller

## Overview

SambaAD is a Lima VM running Samba 4 as a full Active Directory Domain Controller. It simulates an on-premises ADDS (Active Directory Domain Services) environment, acting as the enterprise identity source for the lab.

| Property | Value |
|----------|-------|
| VM name | `samba-ad` |
| Hypervisor | Lima (ARM64 Ubuntu 24.04) |
| Domain | `corp.internal` |
| NetBIOS name | `CORP` |
| VM IP | Dynamic (Lima DHCP — captured at setup time) |
| LDAP port | 389 |
| Kerberos port | 88 |
| DNS port | 53 (Samba internal DNS) |

## Azure equivalent

| Lab | Azure |
|-----|-------|
| SambaAD (Lima VM) | On-premises Active Directory / Entra ID |

## Domain configuration

| Setting | Value |
|---------|-------|
| Realm | `CORP.INTERNAL` |
| DNS backend | `SAMBA_INTERNAL` (Samba serves `corp.internal` authoritatively) |
| DNS forwarder | `8.8.8.8` (for external resolution) |
| Admin account | `Administrator` |
| Admin password | `AksLab!AdDev1` |

## Lab users

| Username | Password | OU |
|----------|----------|----|
| `testuser1` | `AksLab!User1` | `OU=lab-users,DC=corp,DC=internal` |
| `testuser2` | `AksLab!User2` | `OU=lab-users,DC=corp,DC=internal` |

Both users are members of the `lab-users` group.

## How DNS works

CoreDNS is patched at setup/resume time to forward `corp.internal` queries to the SambaAD VM IP:

```
corp.internal:53 {
  forward . <samba-ad-ip>
}
```

This means pods inside the cluster resolve AD SRV records (`_ldap._tcp.corp.internal`, `_kerberos._tcp.corp.internal`) correctly, just as a domain-joined machine would.

## Common commands

```bash
# Inspect the domain
limactl shell samba-ad -- samba-tool domain info 127.0.0.1

# List users
limactl shell samba-ad -- samba-tool user list

# Show a user's attributes
limactl shell samba-ad -- samba-tool user show testuser1

# List groups
limactl shell samba-ad -- samba-tool group list

# Check Kerberos config
limactl shell samba-ad -- cat /etc/krb5.conf

# Test LDAP from Mac (requires ldap-utils: brew install openldap)
SAMBA_IP=$(limactl shell samba-ad -- ip -4 addr show lima0 \
  | awk '/inet /{print $2}' | cut -d/ -f1)

ldapsearch -H ldap://$SAMBA_IP:389 \
  -x -D "Administrator@corp.internal" -w "AksLab!AdDev1" \
  -b "OU=lab-users,DC=corp,DC=internal" "(objectClass=person)" \
  cn sAMAccountName userPrincipalName
```

## Provisioning

Created by `IaC/terraform/samba.tf` (`null_resource.samba_vm`) via `terraform apply`.  
Destroyed by `terraform destroy` or `teardown-lab.sh`.

### Faster provisioning with Packer

On first provision Terraform launches a plain Ubuntu 24.04 VM and cloud-init installs the samba packages (~5 min). You can eliminate that wait by pre-building a Packer base image with the packages already baked in:

```bash
IaC/packer/build.sh samba
```

The image is saved to `~/.lab-cache/images/samba-base.tar.gz`. Terraform detects it automatically on the next `terraform apply` and launches from the cache instead of pulling Ubuntu 24.04 fresh. Domain provisioning (samba-tool, user creation) still runs via cloud-init at apply time since it requires the domain name and credentials.

See also: [corp-client.md](../tools/corp-client.md), [dex.md](dex.md), [auth-walkthrough.md](../guides/auth-walkthrough.md), [packer.md](../iac/packer.md)
