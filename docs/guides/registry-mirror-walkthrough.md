# Registry Mirror Walkthrough

A three-stage guide to the **docker.io pull-through cache** that runs as a standard part of this lab. The cache is a `registry:2` container in Colima that every minikube node uses as a transparent proxy for Docker Hub pulls — no configuration required, always on.

Prerequisites: a running lab (`./aks-lab resume` or `./aks-lab setup`).

---

## Stage 1 — The problem: Docker Hub rate limits and flaky pulls

### What goes wrong without a cache

Docker Hub imposes rate limits on anonymous pulls: 100 pulls per 6 hours per source IP. A three-node lab cluster working through a deployment-heavy guide can exhaust that budget in a single session. When it happens, image pulls start failing with:

```text
toomanyrequests: You have reached your pull rate limit.
```

There is a second problem specific to this lab's network path. Traffic from cluster pods flows:

```text
pod → containerd → minikube node container → Colima VM → QEMU NAT → home router → Docker Hub
```

Docker Hub advertises two A records. One of them is occasionally unreachable from this path, making cold pulls for uncached images time out before eventually succeeding on the second IP — or fail entirely if the agent startup timeout is too short.

### How the mirror fixes both

A `registry:2` container runs inside the Colima VM and acts as a pull-through proxy for `docker.io`. Each node's containerd is configured to try `http://192.168.49.1:5000` first; only on a cache miss does the registry itself reach out to Docker Hub — once, regardless of how many nodes are pulling the same image.

```bash
# See the current mirror config on the control-plane node
docker exec aks-lab cat /etc/containerd/certs.d/docker.io/hosts.toml
```

Expected output:

```toml
server = "https://registry-1.docker.io"

[host."http://192.168.49.1:5000"]
  capabilities = ["pull", "resolve"]
```

Verify all three nodes are configured:

```bash
for node in $(minikube node list -p aks-lab | awk '{print $1}' | tr '[:upper:]' '[:lower:]'); do
  echo -n "$node: "
  docker exec "$node" grep -c '192.168.49.1:5000' \
    /etc/containerd/certs.d/docker.io/hosts.toml 2>/dev/null \
    && echo "configured" || echo "MISSING"
done
```

---

## Stage 2 — Watching the cache in action

### Before: confirm the registry is running

```bash
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  docker ps --filter name=registry-mirror --format 'table {{.Names}}\t{{.Status}}'
```

### Snapshot the cache catalogue before a pull

```bash
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  curl -s http://localhost:5000/v2/_catalog | python3 -m json.tool
```

Note the current list of repositories.

### Pull an image that is not yet cached

```bash
# Choose an image that isn't in the catalogue above, e.g. redis:7-alpine
kubectl run cache-test --image=redis:7-alpine --restart=Never -- sleep 3600
kubectl wait pod cache-test --for=condition=Ready --timeout=60s
```

### Confirm it landed in the cache

```bash
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  curl -s http://localhost:5000/v2/_catalog | python3 -m json.tool
# library/redis should now appear

DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  curl -s http://localhost:5000/v2/library/redis/tags/list | python3 -m json.tool
```

### Pull the same image on a second node — served from cache

Delete the pod (which removes the image from the node's local store after a while) and reschedule it on a different node:

```bash
kubectl delete pod cache-test

# Force it onto a worker node
kubectl run cache-test --image=redis:7-alpine --restart=Never \
  --overrides='{"spec":{"nodeName":"aks-lab-m02"}}' -- sleep 3600
```

Watch the containerd pull log on that node — the pull completes in milliseconds because the bytes come from `192.168.49.1:5000`, not the internet:

```bash
docker exec aks-lab-m02 journalctl -u containerd -n 20 --no-pager | grep -i redis
```

Clean up:

```bash
kubectl delete pod cache-test
```

---

## Stage 3 — Persistence, lifecycle, and troubleshooting

### Where the data lives

The cached layers are stored in a named Docker volume inside Colima:

```bash
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  docker volume inspect registry-mirror-data \
  | python3 -c "import json,sys; v=json.load(sys.stdin)[0]; print(v['Mountpoint'])"
```

The volume survives container restarts, Colima restarts, and `./aks-lab resume`. It is only cleared if you explicitly remove it.

### What happens on resume

`--restart always` means the `registry-mirror` container auto-starts whenever Colima's Docker daemon comes up. `./aks-lab resume` also calls `lab_registry_mirror_start` explicitly as a belt-and-braces check, and `lab_registry_mirror_configure` rewrites `hosts.toml` on any node where it is missing (idempotent).

### Checking the upstream hit rate

The registry logs every request — `MISS` means it fetched from Docker Hub, `HIT` means it served from local storage:

```bash
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
  docker logs registry-mirror --tail=30 2>&1 | grep -E 'GET|MISS|HIT'
```

### Flushing the cache

The volume grows without bound. To reclaim disk space:

```bash
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock docker stop registry-mirror
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock docker rm   registry-mirror
DOCKER_HOST=unix://$HOME/.colima/default/docker.sock docker volume rm registry-mirror-data
```

The next `./aks-lab resume` (or `lab_registry_mirror_start` directly) recreates the container and an empty volume.

### Azure equivalent

Azure Container Registry Premium supports pull-through cache rules. You configure an upstream source (Docker Hub, ghcr.io, etc.) and ACR proxies and caches pulls transparently. AKS nodes are pointed at the ACR endpoint via `--attach-acr` at cluster creation or via an `imagePullSecret`. The containerd `certs.d/hosts.toml` mechanism used here is exactly what AKS configures on its nodes when you enable ACR integration.

**What you have learned:** how a pull-through cache eliminates Docker Hub rate-limit failures, how containerd's `certs.d` mirror config works at the node level, and how cached layers are stored and served — the same concepts that underpin ACR pull-through cache in production AKS.
