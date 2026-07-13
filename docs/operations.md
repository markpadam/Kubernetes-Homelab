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
| `./aks-lab doze [on\|off\|now\|status]` | Auto-pause the lab after idle hours (Mac stays awake for pihole/DNS; `--sleep` to also sleep it) | See [Power saving](#power-saving-auto-doze) |
| `./aks-lab wake [--wait]` | Wake-on-LAN the lab host from another machine | Run on the client (MacBook); grants a 10-min wake window |

The usual daily rhythm: **`doze now`** (or just walk away — auto-doze pauses and
sleeps the Mac after 2 h idle), then **`wake` + `resume`** when you come back.
A full `setup` is only needed for a fresh build or after a `teardown`.

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

#### From outside the LAN (over the internet)

Use a private overlay (Tailscale) rather than port-forwarding — `publish`
auto-binds the tailnet, and `LAB_SSH_HOST=<tailnet-ip> ./aks-lab dashboard`
reaches the dashboard. Full guide (incl. the Cloudflare option and what to never
expose): [network-setup → Remote access over the internet](network-setup.md#remote-access-over-the-internet).

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

Setup prompts for a tier (or set `LAB_RESOURCE_TIER=1..6`). **3 nodes is the
supported maximum** on this hardware — a 4th node overloads the API server on a
cold resume.

| Tier | Per node | Cluster | Colima | For |
|------|----------|---------|--------|-----|
| 1 Low | 2 CPU / 3 GB ×3 | 9 GB | ~12 GB | minimal |
| 2 Standard | 2 CPU / 4 GB ×3 | 12 GB | ~14 GB | recommended default |
| 3 High | 3 CPU / 5 GB ×3 | 15 GB | ~18 GB | full feature set |
| 4 Very High | 4 CPU / 7 GB ×3 | 21 GB | ~24 GB | all services + replicas |
| 5 Extra High | 4 CPU / 10 GB ×3 | 30 GB | ~34 GB | 48 GB Mac Pro |
| 6 Maximum | 6 CPU / 14 GB ×3 | 42 GB | ~44 GB / 20 VM CPU | dedicated 24-thread / 64 GB Mac Pro |

Tier 6 sizes the Colima VM to 20 real cores (not the per-node count) so the
three node containers stop starving each other — the root cause of flaky
pod-to-internet egress on the dedicated box.

Setup **auto-sizes Colima** for the chosen tier. Give Colima real CPU headroom
on a 12-core Mac Pro — e.g. `colima start --cpu 8 --memory 32` — which also helps
the cluster absorb the reconnection load on a cold resume.

---

## Power saving (auto-doze)

An idle lab still burns ~5–6 host cores (QEMU + cluster control loops) — roughly
60–90 W of electricity around the clock. Auto-doze pauses the lab and sleeps the
Mac once nothing has used it for a while — or immediately on demand:

```bash
./aks-lab doze on              # after 2h idle: pause --colima (Mac stays awake for pihole/DNS)
./aks-lab doze on --hours 4    # longer idle window
./aks-lab doze on --sleep      # also sleep the Mac after pausing (needs Wake-on-LAN)
./aks-lab doze now             # "done for the day" — pause right away
./aks-lab doze status          # agent state, current activity signals, log tail
./aks-lab doze off             # disable
```

“Activity” = an interactive SSH session, a Screen Sharing client, a remote
kubectl/web connection (`:8443`/`:9980`), any `./aks-lab` invocation, an
authenticated dashboard request, or a lab operation in flight. The agent checks
every 15 minutes (`/tmp/aks-lab-doze.log` records each decision) and refuses to
sleep unless Wake-on-LAN is enabled (`sudo pmset -a womp 1 autorestart 1`).

Waking back up from another machine:

```bash
./aks-lab wake --wait          # WoL burst + wait; grants a 10-min wake window
ssh mac-pro "cd ~/Documents/Kubernetes-Homelab && nohup ./aks-lab resume &"
```

Resume from a doze takes ~15 minutes on the Mac Pro (Colima cold boot included).

Two invariants keep the cycle safe: doze **never sleeps a box that can't be
woken** (requires `womp 1`), and a **running lab pins the Mac awake** — resume
holds a `caffeinate -s` assertion that pause releases, because a bare WoL wake
is only a ~45 s macOS *DarkWake* that would otherwise fall back asleep.

**Full guide** — architecture, activity signals, the DarkWake/wake-assertion
model, Wi-Fi vs Ethernet wake behaviour, troubleshooting:
**[guides/doze-power-saving.md](guides/doze-power-saving.md)**.

---

## Troubleshooting playbook

Hard-won fixes for the things that actually go wrong on this stack.

### `doctor` first
`./aks-lab doctor` catches the common pre-deploy blockers (Colima stopped or
undersized, missing `qemu`/`jq`/`socket_vmnet` sudoers, dnsmasq not answering)
and — on a running cluster — verifies all four control-plane static-pod
manifests are present (see below).

### SSH to the Mac Pro times out
It's probably dozing (auto-doze sleeps the Mac after 2 h idle — see
[Power saving](#power-saving-auto-doze)). From another machine:
`./aks-lab wake --wait`, then SSH in within the 10-minute wake window and
`resume`. Wake takes 5–10 s from light sleep, up to ~3 min from deep standby.

### Cluster looks "up" but nothing reconciles / new pods never schedule
Symptoms seen together: `kubectl get nodes` all Ready, but Deployments never
progress, `kube-dns` Endpoints point at a stale pod IP (all service DNS times
out), and Flux reports `Source artifact not found`. Cause: the
**kube-controller-manager / kube-scheduler static-pod manifests are missing**
from `/etc/kubernetes/manifests/` on the control-plane node — `minikube start`
happily reports such a cluster as healthy. `doctor` flags it; fix with:
```bash
docker exec aks-lab sh -c '/var/lib/minikube/binaries/v1.32.0/kubeadm init phase control-plane controller-manager --config /var/tmp/minikube/kubeadm.yaml \
  && /var/lib/minikube/binaries/v1.32.0/kubeadm init phase control-plane scheduler --config /var/tmp/minikube/kubeadm.yaml'
```
Endpoints reconcile within seconds of the controller-manager starting.

### `docker` unreachable but `colima status` says running
Lima's SSH-forwarded plumbing (docker.sock + the API port) can wedge while the
VM — and the whole cluster inside it — stays healthy. `colima start` is a
no-op in this state; only `colima restart` rebuilds the forwards. `resume`
detects and handles this automatically; run it (or `colima restart`) rather
than debugging the socket.

### `feature enable cilium` refuses to install
Deliberate: chained Cilium on this kindnet/DinD minikube splits pod networking
across two datapaths (kubelet can't probe Cilium-wired pods — random
CrashLoops, and CoreDNS can be taken down with it). Cilium as the **sole** CNI
is the supported route: `./aks-lab teardown && LAB_CNI=cilium ./aks-lab setup`.
`LAB_CILIUM_FORCE=1` overrides the guard at your own risk.

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
4. **PKI intermediate has a key + default issuer?** `vault list pki_int/keys` (must be non-empty) and `vault read pki_int/config/issuers`. A 500 of "no default issuer" or "unable to fetch corresponding key for issuer" means the chain came back keyless after a Vault wipe — a **plain terraform apply will NOT fix it** (the chain resources are write-only to the provider). Resume detects and repairs this automatically; manually, force-recreate the chain:
   ```bash
   terraform -chdir=IaC/terraform apply -auto-approve \
     -var=minikube_profile=aks-lab -var="minikube_k8s_host=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" \
     -replace=vault_pki_secret_backend_root_cert.root \
     -replace=vault_pki_secret_backend_intermediate_cert_request.int \
     -replace=vault_pki_secret_backend_root_sign_intermediate.int \
     -replace=vault_pki_secret_backend_intermediate_set_signed.int
   ```
5. **cert-manager backing off?** It backs off for up to an hour after repeated failures; once the above is fixed, force a clean retry: `kubectl delete certificates -A --all` (ingress-shim recreates them immediately).

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
| `/tmp/aks-lab-doze.log` | auto-doze decisions + pause/sleep output |
| `/tmp/aks-lab-last-activity` | doze idle-clock heartbeat (touched by every `./aks-lab` call) |
| `/tmp/aks-lab-caffeinate.pid` | wake assertion held while the lab runs |
| `~/.aks-lab-doze.conf` | doze settings (idle hours, sleep on/off) |
| `.lab-state.json` (repo root) | enabled-features state (backed up to `/tmp/lab-state.json.bak` on teardown) |
| `/tmp/aks-lab-kubeconfig.yaml` | external kubeconfig for other machines |
| `~/.aks-lab-secrets` | persistent lab secrets (cookie/dex) |
