# Falco

Falco is a CNCF runtime-security tool. It taps Linux kernel syscalls (via eBPF or the legacy kernel module) and matches them against a rule set in real time — shells in containers, writes to `/etc`, network connections to unexpected hosts, privilege escalation, sensitive mounts.

In production AKS Falco is the runtime detection layer that complements admission-time controls like Kyverno. Kyverno stops bad workloads from being deployed; Falco watches what they actually do once they're running.

## How it works

Falco runs as a DaemonSet on every node:

| Component | Role |
|-----------|------|
| `falco` (DaemonSet) | Loads the eBPF probe, evaluates rules against syscalls, emits events |
| `falcosidekick` (Deployment) | Event router — forwards Falco events to Slack/webhooks/Loki/etc. |
| `falcosidekick-ui` (Deployment) | Web UI to browse recent events |

Detection rules live in YAML — community-maintained rule packs ship with the chart and you can layer custom rules on top.

## Rule packs shipped by default

| Rule pack | Examples |
|-----------|----------|
| `falco_rules.yaml` (core) | Shell in container, write below `/etc`, unexpected outbound connection, container privileged mount |
| `k8s_audit_rules.yaml` | Disallow `kubectl exec`, detect ServiceAccount token mount, alert on cluster-admin role binds |
| `application_rules.yaml` | Process trees that don't match the parent container (e.g. `bash` inside `nginx`) |

Custom rules are written in the same DSL:

```yaml
- rule: Suspicious kubectl exec into payments pod
  desc: Anyone exec-ing into the payments namespace is paging-worthy
  condition: >
    kevt and exec and ka.target.namespace = "payments"
  output: "kubectl exec into payments pod (user=%ka.user.name target=%ka.target.pod)"
  priority: WARNING
  source: k8s_audit
```

## Lab setup

```bash
./aks-lab feature enable falco
```

Web UI: <https://falco.aks-lab.local:9444/> (gated by OAuth2 Proxy SSO when `oauth2-proxy` is enabled).

## Useful commands

```bash
# Falco DaemonSet status — one pod per node
kubectl get pods -n falco -o wide

# Live-stream Falco detections in the terminal
kubectl logs -n falco -l app.kubernetes.io/name=falco -f --tail=20

# Browse events in falcosidekick-ui
open https://falco.aks-lab.local:9444/

# Trigger a noisy detection to confirm Falco is alive
kubectl run alpine-shell --rm -it --image=alpine -- sh
# Inside the container: cat /etc/shadow   ← Falco should fire "Read sensitive file untrusted"
```

## Performance note

Falco's modern-eBPF probe is low-overhead but every syscall still has to be evaluated against the rule set. On a memory-constrained lab this is usually fine, but it does add ~50–150 MB per node. The DaemonSet defaults to running with no resource limits because tightening eBPF can cause it to drop events. The lab values cap memory at 1 GB and CPU is requests-only.

## Azure equivalent

**Microsoft Defender for Containers** provides runtime threat detection on AKS — it uses a similar eBPF-based agent under the hood. Falco is the open-source baseline; Defender adds Azure-native alerting, Microsoft Sentinel integration, and managed rule updates.

In production it's common to run Falco for granular custom rules and forward events to Sentinel via the falcosidekick webhook output.

See the [Falco walkthrough](../guides/falco-walkthrough.md) for hands-on rule tuning and incident simulation.
