# Packer — VM Base Image Builder

## Overview

HashiCorp Packer pre-builds base images for the two Multipass VMs in the identity stack (`samba-ad` and `corp-client`). Packages are baked in once and cached locally; Terraform launches subsequent VMs from the cache instead of installing from scratch.

| VM | Without Packer | With Packer cache |
|----|---------------|-------------------|
| `samba-ad` | ~5 min (apt install samba + winbind stack) | ~1 min (domain provision only) |
| `corp-client` | ~20 min (XFCE4 + k8s tools + Azure CLI + Firefox) | ~2 min (domain join + VNC config only) |

The Packer templates live in `IaC/packer/`, alongside `IaC/terraform/`. Images are saved to `~/.lab-cache/images/` — the same cache directory used for container images. Terraform detects the cache automatically; there is no configuration required.

## Prerequisites

Packer must be installed (it is not needed for a standard lab run). It is included in the lab prereqs script:

```bash
./aks-lab prereqs
```

Or install manually:

```bash
brew install packer
```

Multipass 1.14 or later is required for `multipass export`. Check your version:

```bash
multipass version
```

If Multipass is older, upgrade before building images:

```bash
brew upgrade multipass
```

## Build images

```bash
# Build both images (recommended before first identity stack provision)
IaC/packer/build.sh

# Build only the samba-ad base image
IaC/packer/build.sh samba

# Build only the corp-client base image
IaC/packer/build.sh corp-client

# Force a rebuild even if the cache already exists
IaC/packer/build.sh --force
IaC/packer/build.sh samba --force
```

Build times (approximate, depends on network speed):

| Image | Size on disk | Build time |
|-------|-------------|-----------|
| `samba-base.tar.gz` | ~300–400 MB | ~5–8 min |
| `corp-client-base.tar.gz` | ~1.5–2.5 GB | ~20–30 min |

## How it works

1. `build.sh` checks `~/.lab-cache/images/` for each `.tar.gz` file. If found and `--force` is not set, it skips the build.
2. Packer launches a clean Ubuntu 24.04 Multipass VM, runs shell provisioners to install packages, resets cloud-init, then exports the stopped VM with `multipass export`.
3. The exported `.tar.gz` is saved to `~/.lab-cache/images/`.
4. On the next `terraform apply`, `IaC/terraform/samba.tf` checks for the cached image and passes `file://~/.lab-cache/images/<image>.tar.gz` to `multipass launch` instead of `24.04`. Cloud-init still runs at apply time but skips the package installation phase.

## What each image contains

### samba-base

Packages pre-installed — no domain-specific configuration:

- `samba`, `winbind`, `krb5-user`, `attr`, `acl` — Samba AD stack
- `dnsutils`, `ldap-utils` — DNS and LDAP diagnostics
- `socat` — IPv4↔IPv6 DNS proxy (required by the lab's DNS setup)

### corp-client-base

A fully-tooled Ubuntu 24.04 desktop, ready for domain join:

| Category | Tools |
|----------|-------|
| Domain join | `realmd`, `sssd`, `sssd-tools`, `adcli`, `krb5-user` |
| Desktop | XFCE4, `tigervnc-standalone-server`, `dbus-x11` |
| Browsers | Firefox (Mozilla PPA — no snap), Sublime Text |
| Kubernetes | `kubectl` (v1.31), `helm`, `k9s`, `kubectx`, `kubens` |
| GitOps | `flux`, `argocd` (ArgoCD CLI), `argo` (Argo Workflows CLI) |
| HashiCorp | `vault` |
| Azure | `az` (Azure CLI + azure-devops extension), `azcopy` |
| Observability | `stern` (multi-pod log tailing) |
| Utilities | `jq`, `yq`, `curl`, `wget`, `dnsutils`, `net-tools` |

Shell completions and aliases for all tools are pre-configured in `/home/ubuntu/.bashrc`.

**Not baked in** (requires runtime values from cloud-init at apply time):

- DNS configuration (needs the Samba VM IP)
- Domain join (`realm join` — needs domain name and admin password)
- VNC password
- `/etc/hosts` cluster service entries (needs the Multipass gateway IP)
- `kubeconfig` (needs the Mac host IP)

## Sharing images

Images are local to `~/.lab-cache/images/` by default. To share across machines:

- **GitHub Release asset** — upload the `.tar.gz` as a release artifact; teammates download and place it in `~/.lab-cache/images/`.
- **Azure Blob Storage** — upload via `azcopy copy samba-base.tar.gz "https://<account>.blob.core.windows.net/lab-images/samba-base.tar.gz"`.

The Packer templates in `IaC/packer/` are committed to the repo — teammates can always build the images themselves if no pre-built cache is available.

## Rebuild after changes

Packer images are not automatically rebuilt when `cloud-init` templates change. If you modify `IaC/terraform/cloud-init/samba-ad.tpl.yaml` or `corp-client.tpl.yaml`, check whether those changes affect the package list. If so, rebuild:

```bash
IaC/packer/build.sh --force
```

## File reference

```text
IaC/packer/
├── build.sh                              # top-level wrapper — cache check + build
├── samba-base.pkr.hcl                    # Packer template for samba-ad base
├── corp-client-base.pkr.hcl              # Packer template for corp-client base
└── scripts/
    ├── provision-samba-base.sh           # installs samba packages into the VM
    ├── provision-corp-client-base.sh     # installs full desktop + toolchain
    └── export-image.sh                   # exports VM → tar.gz, purges build instance
```

See also: [samba-ad.md](../services/samba-ad.md), [corp-client.md](../tools/corp-client.md)
