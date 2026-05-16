# Toolbox

**Namespace:** `toolbox`  
**SSH:** `ssh aks-toolbox` or `ssh root@localhost -p 2222`  
**Source:** `toolbox/`

## Overview

The toolbox is an Ubuntu pod that runs inside the cluster and exposes SSH on `localhost:2222`. It provides a shell from which you can debug cluster networking, run `kubectl` commands, test DNS resolution, and interact with services from within the cluster network — without needing to exec into application pods.

## Connecting

```bash
ssh aks-toolbox
```

The `aks-toolbox` SSH alias is configured in `~/.ssh/config` by `setup-lab.sh`:

```
Host aks-toolbox
  HostName localhost
  Port 2222
  User root
  StrictHostKeyChecking no
```

Or connect directly:
```bash
ssh root@localhost -p 2222
```

## SSH Key

The toolbox accepts connections with your local SSH public key (`~/.ssh/id_ed25519.pub` or `id_rsa.pub`). `setup-lab.sh` injects the key into the `toolbox-ssh-keys` ConfigMap at cluster setup time, replacing the `REPLACE_WITH_YOUR_PUBLIC_KEY` placeholder.

## Networking

The toolbox runs inside the cluster and uses the cluster's CoreDNS for resolution. From the toolbox you can:

- Resolve `corp.internal` and `privatelink.*` names via Bind9
- Reach any ClusterIP or service DNS name directly
- Test connectivity to emulators before adding port-forwards

**Useful debugging commands from the toolbox:**
```bash
nslookup sqlserver.corp.internal
nslookup mysqlserver.privatelink.database.windows.net
curl http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1
curl http://cosmosdb.cosmos-db.svc.cluster.local:8081/_explorer/index.html
```

## Service

The toolbox service is a `NodePort` that Minikube port-forwards to `localhost:2222`.

| Setting | Value |
|---------|-------|
| NodePort | 30022 |
| Container port | 22 (sshd) |

## Image

The `aks-lab/toolbox:latest` image is built from `toolbox/Dockerfile` and loaded into Minikube's Docker daemon by `setup-lab.sh`. It is based on Ubuntu and includes common debugging tools (curl, nslookup, etc.).

## Configuration

| Setting | Value |
|---------|-------|
| `imagePullPolicy` | `Never` |
| SSHD config | `toolbox/sshd_config` |
| MOTD | `toolbox/motd` |
| Memory limit | 512 Mi |
| CPU limit | 500m |

## Probes

Both readiness and liveness probe via TCP socket on port 22.
