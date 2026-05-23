# Kubernetes Dashboard

**Namespace:** `kubernetes-dashboard`
**URL:** `https://dashboard.aks-lab.local:9444`
**Managed by:** `./aks-lab feature enable kubernetes-dashboard` (dispatches to `scripts/lab-feature.sh`)

## Overview

Kubernetes Dashboard is the official web-based UI for exploring cluster resources, workloads, and logs. In AKS Homelab it provides a cluster-level view of deployments, services, pods, ConfigMaps, and Secrets.

The Dashboard is exposed through the NGINX ingress controller and is typically protected by the lab's OAuth2 SSO stack when `oauth2-proxy` is enabled.

## How to enable

```bash
./aks-lab feature enable kubernetes-dashboard
```

If the component is already enabled, the command is idempotent.

## Access

Open `https://dashboard.aks-lab.local:9444` in your browser. If OAuth2 Proxy is enabled, you will authenticate through Dex using the lab SSO account.

## Deployment

The Dashboard is deployed via the `flux/infrastructure/base/kubernetes-dashboard/` manifests. The ingress resource is configured to route `dashboard.aks-lab.local` through NGINX to the dashboard service.

## Notes

- The dashboard UI is useful for cluster inspection, but it is not intended as the primary control plane for the lab.
- If `oauth2-proxy` is disabled, the Dashboard may still be reachable directly depending on the ingress configuration.
- The dashboard is not managed by Flux as a perpetual component; it is applied through the lab feature toggle system.
