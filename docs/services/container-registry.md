# Container Registry

**Namespace:** `container-registry`  
**Azure equivalent:** Azure Container Registry  
**Managed by:** Flux (`flux/apps/base/container-registry/`)

## Overview

Docker Registry v2 provides an OCI-compliant image registry inside the cluster. It is used to store and serve container images built locally, removing the need to push to an external registry during development. The image (`registry:2`) is native ARM64.

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 5000 | HTTP | Registry API (OCI Distribution Spec v1) |

Port-forwarded to `localhost:5000` by `./aks-lab resume` / `./aks-lab setup`.

## Authentication

No authentication is configured. The registry is open and accessible to any pod in the cluster and to the Mac host via the port-forward.

## Using the Registry

**Tag and push an image from the Mac:**

```bash
docker tag my-image localhost:5000/my-image:latest
docker push localhost:5000/my-image:latest
```

**Reference the image from a Kubernetes manifest:**

```yaml
image: registry.container-registry.svc.cluster.local:5000/my-image:latest
```

**List repositories:**

```bash
curl http://localhost:5000/v2/_catalog
```

**List tags for an image:**

```bash
curl http://localhost:5000/v2/my-image/tags/list
```

## DNS

`registry.container-registry.svc.cluster.local` — standard in-cluster DNS.

Bind9 also serves:

- `registry.corp.internal` → registry ClusterIP
- `myregistry.privatelink.azurecr.io` → registry ClusterIP

## Storage

A 10 Gi `PersistentVolumeClaim` (`registry-data`) mounts at `/var/lib/registry`. Images survive pod restarts.

## Configuration

| Setting | Value |
|---------|-------|
| Image | `registry:2` |
| Storage root | `/var/lib/registry` |
| Auth | None |
| Memory limit | 256 Mi |
| CPU limit | 250m |

## Probes

Both readiness and liveness probe via HTTP GET `/v2/` on port 5000.
