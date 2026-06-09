# Registry Mirror (docker.io pull-through cache)

**Runs in:** Colima VM (Docker container, outside the cluster)
**Managed by:** `scripts/lib-common.sh` `lab_registry_mirror_start` / `lab_registry_mirror_configure`
**Default:** yes — started automatically by `./aks-lab setup` and `./aks-lab resume`
**Azure equivalent:** Azure Container Registry with pull-through cache (Premium tier)

## Overview

A `registry:2` container running inside Colima acts as a transparent pull-through proxy for `docker.io`. Every `docker.io` image pull from any cluster node hits the local cache first; only a cache miss reaches the internet. On a cache hit the image comes from the local Colima VM at LAN speed.

This solves two problems specific to this lab:

- **Docker Hub rate limits** — anonymous pulls are limited to 100/6 h per IP. A three-node cluster working through a lab guide can hit that ceiling in a single session. The mirror shares one upstream identity across all nodes.
- **Flaky outbound connectivity** — the Colima → internet path has occasional timeouts (one of Docker Hub's two IPs is sometimes unreachable). A cached image is served immediately with no upstream round-trip.

## Architecture

```
Pod on any node
  └─ containerd (docker.io mirror: http://192.168.49.1:5000)
       ├─ cache HIT  → registry:2 in Colima          (fast, no internet)
       └─ cache MISS → registry:2 → registry-1.docker.io  (one upstream fetch)
```

The `registry:2` container binds to `0.0.0.0:5000` inside the Colima VM. The Colima VM's IP on the minikube bridge (`192.168.49.1`) is reachable from every node container. Each node's containerd is configured with `/etc/containerd/certs.d/docker.io/hosts.toml` pointing at `http://192.168.49.1:5000` as the mirror endpoint.

## Persistence

Images are stored in a named Docker volume (`registry-mirror-data`) inside Colima. The volume survives container restarts and Colima restarts. A cold restart of the whole Mac flushes nothing — the volume persists on the Colima VM's disk.

## Startup behaviour

The container is created with `--restart always`, so it starts automatically whenever the Colima Docker daemon comes up. `./aks-lab resume` explicitly calls `lab_registry_mirror_start` after Docker is confirmed healthy as a belt-and-braces check.

## Verify

```bash
# Confirm the container is running in Colima
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock docker ps --filter name=registry-mirror

# Confirm hosts.toml is written on every node
for node in $(minikube node list -p aks-lab | awk '{print $1}' | tr '[:upper:]' '[:lower:]'); do
  echo "=== $node ==="
  docker exec "$node" cat /etc/containerd/certs.d/docker.io/hosts.toml
done

# Pull an image and confirm it comes from the local mirror
# (check the registry catalog before and after)
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  curl -s http://localhost:5000/v2/_catalog | python3 -m json.tool
kubectl run test --image=nginx:alpine --restart=Never
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  curl -s http://localhost:5000/v2/_catalog | python3 -m json.tool
kubectl delete pod test
```

## Inspect cached images

```bash
# List all cached repositories
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  curl -s http://localhost:5000/v2/_catalog | python3 -m json.tool

# List tags for a specific repository
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  curl -s http://localhost:5000/v2/library/nginx/tags/list | python3 -m json.tool
```

## Configuration

| Setting | Value |
|---------|-------|
| Image | `registry:2` |
| Container name | `registry-mirror` |
| Upstream | `https://registry-1.docker.io` |
| Listen address | `0.0.0.0:5000` (Colima VM) |
| Mirror URL (nodes) | `http://192.168.49.1:5000` |
| Cache volume | `registry-mirror-data` (named Docker volume in Colima) |
| Restart policy | `always` |

## Troubleshooting

**Mirror container not running**
```bash
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock docker start registry-mirror
```

**Node not using the mirror (hosts.toml missing)**

Re-run configure (idempotent):
```bash
source scripts/lib-common.sh
lab_registry_mirror_configure aks-lab
```

**Cache miss still going to internet** — expected on first pull of any image. Subsequent pulls of the same tag are served from cache.

**Disk pressure in Colima** — the volume grows unboundedly. To flush it:
```bash
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock docker stop registry-mirror
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock docker rm registry-mirror
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock docker volume rm registry-mirror-data
# ./aks-lab resume will recreate it
```

## Azure equivalent

Azure Container Registry **Premium** tier supports pull-through cache rules — you configure an upstream (Docker Hub, ghcr.io, etc.) and ACR proxies and caches pulls transparently. AKS nodes are configured to use the ACR endpoint as the mirror via `--attach-acr` or an `imagePullSecret`. This lab's `registry:2` + containerd `hosts.toml` pattern is functionally identical, just on-premise.
