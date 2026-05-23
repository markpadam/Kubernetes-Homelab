# ArgoCD

**Runs in:** `argocd` namespace
**HTTPS port:** `9444` (port-forwarded from NGINX ingress port 443)
**Hostname:** `https://argocd.aks-lab.local:9444`
**Azure equivalent:** Azure DevOps environments + GitOps connector, or Argo CD on AKS
**Installed by:** `scripts/setup-lab.sh` Step 4b / `scripts/lab-feature.sh` `_enable_argocd` — applies upstream `install.yaml`
**Default:** yes — enabled on every `./aks-lab setup` run

## Overview

ArgoCD is a declarative GitOps continuous-delivery tool. It watches one or more Git repositories, compares the live cluster state against the manifests checked in there, and either auto-syncs or surfaces the drift in its UI.

The lab also runs **Flux** for the same purpose — both controllers coexist. Flux drives the production-style reconciliation (`flux/clusters/dev` and `flux/clusters/prd`), while ArgoCD is available as a familiar UI for exploring applications and sync state.

## Default credentials

After install, the initial admin password is generated and stored in the `argocd-initial-admin-secret` Secret. The dashboard surfaces it; you can also read it directly:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

Username is `admin`.

## Repository connection

If `GITHUB_TOKEN` is configured (via macOS Keychain item `aks-lab-github-token`), the enable function automatically creates an `argocd-repo-homelab` secret that connects ArgoCD to your fork of this repo so you can register Applications without pasting credentials manually.

## Quick access

```bash
# Web UI
open https://argocd.aks-lab.local:9444

# argocd CLI login (if installed)
argocd login argocd.aks-lab.local:9444 --username admin --password <password>
argocd app list
```

## Disabling

```bash
./aks-lab feature disable argocd
```

Deletes the namespace and all Application records. Re-enabling restores ArgoCD itself but does not restore previously registered Applications — those are stored in-cluster, not in Git.

## Azure equivalent

The closest Microsoft-native pattern is Azure DevOps' environments and Multi-Stage Pipelines, which provide approval gates and history but not the declarative diff/reconcile loop. The AKS Flux extension (or any Argo CD install on AKS) is the actual production drop-in.
