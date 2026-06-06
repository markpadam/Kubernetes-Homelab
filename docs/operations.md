# Operating the Lab — Everyday Management

The practical day-to-day guide: lifecycle, accessing the lab from your Mac Pro
**and** a second machine (MacBook), managing components, and a troubleshooting
playbook. For first-time install see the [README](../README.md) and
[system-requirements](system-requirements.md); for the remote-access network
model see [network-setup](network-setup.md).

> **Platform:** Intel Mac on macOS 12 Monterey. Docker via **Colima**, cluster
> via **minikube (docker driver)**, identity VMs via **Lima/QEMU**. Run
> everything from the repo root via the `./aks-lab` dispatcher.

---

## Lifecycle at a glance

| Command | What it does | Notes |
|---------|--------------|-------|
| `./aks-lab doctor` | Read-only preflight — Colima sizing, qemu/jq/socket_vmnet, dnsmasq | Run before `setup`; exits non-zero if anything's wrong |
| `./aks-lab setup [--all\|--minimal\|--standard]` | Build & start the lab (~20–40 min for `--all`) | Auto-sizes Colima, auto-publishes to the LAN at the end |
| `./aks-lab pause [--colima]` | Stop cluster + identity VMs + Vault + port-forwards (keeps all state) | Fast; leaves Colima running unless `--colima` |
| `./aks-lab resume` | Bring the lab back after pause / a Mac reboot | Staggered node start; re-creates Vault, certs, tunnel; auto-publishes |
| `./aks-lab verify` | Post-setup health check (exits 1 on failure) | Good for scripting / CI |
| `./aks-lab teardown [--delete-images]` | Full wipe — cluster, VMs, daemons, dnsmasq, /etc/hosts | Asks to confirm |
| `./aks-lab resize` | Shrink worker-node memory once the cluster has settled | Reclaims RAM after bring-up |
| `./aks-lab refresh [--images\|--restart\|--only <id>]` | Re-apply manifests on a running cluster | No teardown needed |
| `./aks-lab feature <…>` | Enable/disable individual components | See [Managing components](#managing-components) |
| `./aks-lab publish` | (Re)expose the lab to the LAN | Usually automatic — see below |
| `./aks-lab dashboard` | Open the control dashboard locally | Local browser only — remote needs a tunnel |

The usual daily rhythm: **`pause`** when you're done, **`resume`** when you come
back (or it auto-resumes at login). A full `setup` is only needed for a fresh
build or after a `teardown`.

---

## Accessing the lab

### On the Mac Pro itself

- **Web UIs:** `https://grafana.aks-lab.local`, `argocd`, `rancher`, `dashboard`,
  `taskflow`, `blob-explorer`, etc. (HTTPS, real Vault-issued certs).
- **Control dashboard:** `./aks-lab dashboard` → `http://localhost:9997`.
- **kubectl:** works out of the box (the lab configures your kubeconfig context).

### From a second machine (MacBook) on the LAN

`./aks-lab setup` and `resume` **auto-publish** the lab to the LAN (see
[network-setup](network-setup.md) for the model). On the MacBook, one-time:

```bash
# DNS: point *.aks-lab.local (and corp.internal) at the Mac Pro's LAN IP
sudo mkdir -p /etc/resolver
echo "nameserver <MAC_PRO_IP>" | sudo tee /etc/resolver/aks-lab.local
echo "nameserver <MAC_PRO_IP>" | sudo tee /etc/resolver/corp.internal   # if SambaAD enabled

# kubectl: copy the external kubeconfig
scp <you>@<MAC_PRO_IP>:/tmp/aks-lab-kubeconfig.yaml ~/.kube/aks-lab.yaml
export KUBECONFIG=~/.kube/aks-lab.yaml
```

| Want | From the MacBook |
|------|------------------|
| **Web UIs** | Browser → `https://<name>.aks-lab.local`. Trust the Vault root CA once (import `aks-lab.local Root CA` into the keychain) to avoid cert warnings. |
| **kubectl** | Works via the published `:8443` (self-tracking forwarder — survives resumes/reboots). |
| **Non-HTTP services** (SQL 1433, registry 5000, Service Bus 5672, Cosmos 8081, Azurite 10000-2) | Reach them at `<MAC_PRO_IP>:<port>` (published when the feature is enabled). |
| **Vault UI/API** | `http://<MAC_PRO_IP>:8200` (Vault binds all interfaces directly). |
| **Control dashboard** (`:9997`) | **`./aks-lab dashboard`** (SSH tunnel) — see below (deliberately not on the LAN). |

#### Control dashboard from the MacBook — SSH tunnel

The control dashboard has `exec`-into-pods and **teardown** controls, so it stays
bound to `127.0.0.1` for safety and its terminal hardcodes `ws://localhost:9998`.
The simplest path from the MacBook is:

```bash
./aks-lab dashboard
```

It installs a self-healing SSH-tunnel LaunchAgent (forwarding both `9997` and
`9998`, so the terminal works too) that survives sleep and network drops, then
opens `http://localhost:9997`. It needs Remote Login on the Mac Pro plus
`ssh-copy-id <you>@<MAC_PRO_IP>`. To forward by hand instead:

```bash
ssh -fN -L 9997:localhost:9997 -L 9998:localhost:9998 <you>@<MAC_PRO_IP>
# then open http://localhost:9997 on the MacBook
```

On an **iPad**, reproduce the same forward with an SSH app (Blink Shell /
Termius) — see [network-setup](network-setup.md#ipad--ios--access-from-a-tablet).

### When do I need to re-run anything for remote access?

| After… | kubectl | Web UIs | Action |
|--------|---------|---------|--------|
| `pause` → `resume` | keeps working | keep working | none (self-tracking forwarder + persistent daemon) |
| Mac Pro reboot | keeps working | keep working | none (launchd daemons restart) |
| `teardown` → fresh `setup` | **new certs** | keep working | **re-copy the kubeconfig** to the MacBook (new cluster = new CA) |

---

## Managing components

```bash
./aks-lab feature list                 # all components + enabled state
./aks-lab feature status               # live pod health per component
./aks-lab feature enable <id|group>    # enable (auto-resolves dependencies)
./aks-lab feature disable <id> [--force]
```

Common IDs: `vault cert-manager monitoring argocd rancher kubernetes-dashboard
keda kyverno falco istio cilium reflector toolbox samba-ad dex oauth2-proxy
corp-client azurite azure-sql cosmos-db service-bus container-registry taskflow
blob-explorer keda-servicebus argo-workflows azdo-agent`. Full reference:
[lab-features](lab-features.md).

**Re-apply manifests** without a teardown:
```bash
./aks-lab refresh                # re-apply all manifests on the running cluster
./aks-lab refresh --only grafana # just one component
./aks-lab refresh --images       # rebuild & reload the local app images
```

---

## Resource tiers & sizing

Setup prompts for a tier (or set `LAB_RESOURCE_TIER=1..5`). **3 nodes is the
supported maximum** on this hardware — a 4th node overloads the API server on a
cold resume.

| Tier | Per node | Cluster | Colima | For |
|------|----------|---------|--------|-----|
| 1 Low | 2 CPU / 3 GB ×3 | 9 GB | ~12 GB | minimal |
| 2 Standard | 2 CPU / 4 GB ×3 | 12 GB | ~14 GB | recommended default |
| 3 High | 3 CPU / 5 GB ×3 | 15 GB | ~18 GB | full feature set |
| 4 Very High | 4 CPU / 7 GB ×3 | 21 GB | ~24 GB | all services + replicas |
| 5 Extra High | 4 CPU / 10 GB ×3 | 30 GB | ~34 GB | 48 GB Mac Pro |

Setup **auto-sizes Colima** for the chosen tier. Give Colima real CPU headroom
on a 12-core Mac Pro — e.g. `colima start --cpu 8 --memory 32` — which also helps
the cluster absorb the reconnection load on a cold resume.

---

## Troubleshooting playbook

Hard-won fixes for the things that actually go wrong on this stack.

### `doctor` first
`./aks-lab doctor` catches the common pre-deploy blockers (Colima stopped or
undersized, missing `qemu`/`jq`/`socket_vmnet` sudoers, dnsmasq not answering).

### Setup hangs at "Starting minikube tunnel"
A sudo prompt is waiting under the TUI (a very long run can outlive the sudo
cache; the keepalive normally prevents this). Type your password in the setup
terminal. If it's wedged, `Ctrl-C` and re-run `setup` — it skips what's done.

### Resume: API server crash-loops / `kubectl` connection refused
Cold multi-node restarts can overload the API server. Resume now **staggers**
the workers (pause → let the control-plane settle → re-add one at a time). If you
ever hit it manually:
```bash
docker pause aks-lab-m02 aks-lab-m03            # quiet the API
# wait for: kubectl get --raw=/readyz
kubectl delete apiservice v1.ext.cattle.io      # drop Rancher's failing aggregation
docker unpause aks-lab-m02; sleep 20; docker unpause aks-lab-m03   # one at a time
```

### Web UIs unreachable after a resume (HTTP 000 / connection reset)
The minikube tunnel runs as **root** and goes stale when the API port changes on
restart; a user-level `pkill` can't replace it. Resume now uses `sudo pkill`.
Manually:
```bash
sudo pkill -f 'minikube tunnel'   # launchd respawns it fresh against the new port
```

### Web UIs show a cert warning / `curl` says "unable to get local issuer certificate"
The certs are real (Vault-issued); the **Vault root CA** just isn't trusted yet.
Browsers use the keychain — import `aks-lab.local Root CA` once. `curl` uses its
own bundle, so it needs `-k` regardless.

### TLS certs stuck `False` (`kubectl get certificates -A`)
cert-manager can't sign. Check, in order:
1. **Vault up?** `curl -sf http://127.0.0.1:8200/v1/sys/health`
2. **`vault-host` service exists?** `kubectl get svc -n vault vault-host` (setup/resume create it → host gateway `host.minikube.internal:8200`).
3. **ClusterIssuer Ready?** `kubectl get clusterissuer lab-ca -o jsonpath='{.status.conditions[0].message}'`
4. **PKI intermediate has a key + default issuer?** `vault list pki_int/keys` (must be non-empty) and `vault read pki_int/config/issuers`. If a sign returns 500 "no default issuer", the intermediate was set up keyless — re-run the Vault terraform (`terraform -chdir=IaC/terraform apply`).
5. **cert-manager backing off?** It backs off after repeated failures; once the above is fixed, force a clean retry: `kubectl delete certificates -A --all` (ingress-shim recreates them).

### Rancher stuck `0/1` / 503 for a long time
Rancher v2.9+ has a startup deadlock (the `v1.ext.cattle.io` extension API). Setup
and resume break it automatically (publish the extension service's not-ready
endpoint + delete the stale APIService). It still takes ~10–15 min to go Ready
(long probe delays). Manually:
```bash
kubectl patch svc imperative-api-extension -n cattle-system -p '{"spec":{"publishNotReadyAddresses":true}}'
kubectl delete apiservice v1.ext.cattle.io
```

### Lima VMs report wrong status / pause skips them
Fixed (Lima 2.x emits NDJSON; status detection updated). Verify directly:
`limactl list`.

### Useful one-liners
```bash
kubectl get nodes
kubectl get pods -A | grep -vE 'Running|Completed'      # anything unhealthy
kubectl get certificates -A                              # TLS status
minikube status -p aks-lab                               # cluster/apiserver state
tail -f /var/log/minikube-tunnel.log                     # tunnel
tail -f /var/log/lab-publish.log                         # LAN forwarders
tail -f /tmp/vault-dev.log                               # Vault
```

---

## Logs & state reference

| Path | What |
|------|------|
| `/tmp/lab-setup-*.log`, `/tmp/lab-resume-*.log` | setup / resume run logs |
| `/var/log/minikube-tunnel.log` | minikube tunnel (root launchd daemon) |
| `/var/log/lab-publish.log` | LAN socat forwarder daemon |
| `/tmp/vault-dev.log` | Vault dev server |
| `.lab-state.json` (repo root) | enabled-features state (backed up to `/tmp/lab-state.json.bak` on teardown) |
| `/tmp/aks-lab-kubeconfig.yaml` | external kubeconfig for other machines |
| `~/.aks-lab-secrets` | persistent lab secrets (cookie/dex) |
