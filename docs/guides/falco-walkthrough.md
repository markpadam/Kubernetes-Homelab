# Falco Walkthrough

A four-stage hands-on tour of Falco runtime security. We'll watch Falco see what's actually happening inside containers, trigger detections deliberately, tune false positives, and forward events.

Prerequisites:

```bash
./aks-lab feature enable falco
kubectl get pods -n falco          # falco DaemonSet + falcosidekick + UI should be Running
```

---

## Stage 1 — See what Falco sees

**Goal:** confirm the eBPF probe loaded and is processing syscalls.

```bash
# Identify the Falco pod on the same node as where we'll exec the test
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
FALCO_POD=$(kubectl get pods -n falco -l app.kubernetes.io/name=falco --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')

# Stream that pod's log
kubectl logs -n falco "$FALCO_POD" -f --tail=10
```

In a second terminal:

```bash
# Trigger a "Terminal shell in container" detection
kubectl run alpine-shell --rm -it --image=alpine -n default -- sh
# At the alpine prompt:
ls /
exit
```

Back in the log terminal you should see something like:

```text
Notice A shell was spawned in a container with an attached terminal
  (evt_type=execve user=root container_id=... image=alpine ...)
```

That single line is the kind of telemetry production Falco deployments forward to a SIEM.

**What you learn:** Falco rules fire on syscalls, not on Kubernetes API events. It sees what the container actually did, which is hard to spoof.

---

## Stage 2 — Trigger a sensitive-file-read detection

**Goal:** see Falco detect access to `/etc/shadow` from a container.

```bash
kubectl run snoop --rm -it --image=alpine -n default -- sh
# At the prompt:
cat /etc/shadow
exit
```

In the Falco log:

```text
Warning Sensitive file opened for reading by non-trusted program
  (file=/etc/shadow proc=cat ...)
```

The rule that fired is `Read sensitive file untrusted` in `falco_rules.yaml`. The match condition checks `open_read` against a list of sensitive files; "untrusted" means the process is not in the allow-list of expected callers (sshd, login, etc.).

```bash
# Inspect the rule definition Falco loaded
kubectl exec -n falco "$FALCO_POD" -- grep -A 12 "Read sensitive file untrusted" /etc/falco/falco_rules.yaml | head -20
```

**What you learn:** Falco rules ship with curated condition lists for sensitive files, system binaries, and known-evil patterns. You can extend them without rewriting from scratch.

---

## Stage 3 — Tune a noisy rule with a custom override

**Goal:** suppress a false positive without disabling the rule entirely.

Imagine the lab's toolbox SSH pod (a legitimate jump box) keeps triggering the shell-in-container rule. Production-style fix: add a custom rule that overrides the default for that workload.

```bash
cat <<'EOF' > /tmp/falco-custom-rules.yaml
customRules:
  custom-rules.yaml: |-
    - macro: trusted_jumpbox_image
      condition: container.image.repository endswith "/toolbox"

    - rule: Terminal shell in container
      desc: A shell was spawned by a program in a container with an attached terminal.
      condition: >
        spawned_process and container and shell_procs and proc.tty != 0
        and container_entrypoint and not user_expected_terminal_shell_in_container_conditions
        and not trusted_jumpbox_image
      output: >
        A shell was spawned in a container with an attached terminal
        (user=%user.name user_loginuid=%user.loginuid %container.info shell=%proc.name
        parent=%proc.pname cmdline=%proc.cmdline pid=%proc.pid terminal=%proc.tty job_id=%proc.vpid)
      priority: NOTICE
      tags: [container, shell, mitre_execution, T1059]
      override:
        condition: append
EOF

# Apply via helm upgrade — the chart merges customRules into Falco's rules dir
helm upgrade falco falcosecurity/falco -n falco --reuse-values -f /tmp/falco-custom-rules.yaml
kubectl rollout status -n falco daemonset/falco
```

The `not trusted_jumpbox_image` clause tells Falco to skip the rule for any container whose image repo ends with `/toolbox`. Other containers still trigger the alert.

**What you learn:** every shipped rule can be overridden by name. `override.condition: append` adds to the existing condition rather than replacing it — that's the production-safe way to suppress without losing future upstream improvements.

---

## Stage 4 — Forward detections to a webhook (Slack-style)

**Goal:** see how production routes Falco events out of the cluster.

falcosidekick is the event router; it speaks dozens of output formats including Slack, PagerDuty, Loki, S3, and generic webhooks.

```bash
# Start a one-off netcat receiver in the cluster as a fake "Slack endpoint"
kubectl run webhook-sink --image=alpine/socat --restart=Never --rm -it -- \
  -v TCP-LISTEN:8080,fork,reuseaddr SYSTEM:'echo HTTP/1.1 200 OK; echo; cat'
```

Leave that running. In a new terminal:

```bash
# Discover its ClusterIP and patch falcosidekick to forward there
SINK_IP=$(kubectl get pod webhook-sink -o jsonpath='{.status.podIP}')

helm upgrade falco falcosecurity/falco -n falco --reuse-values \
  --set falcosidekick.config.webhook.address="http://${SINK_IP}:8080" \
  --set falcosidekick.config.webhook.minimumpriority=notice

# Trigger another shell-in-container event from Stage 1
kubectl run noisy --rm -it --image=alpine -n default -- sh -c 'echo hi; sleep 1'
```

The webhook-sink terminal should print the JSON event Falco sent. That's the same payload you'd see arrive in Slack, PagerDuty, or a SIEM ingest endpoint.

**What you learn:** Falco's value is what you do with its events. The detection is half the system; routing those events into your existing alert plumbing is the other half.

---

## Cleanup

```bash
# Remove the custom override and webhook
helm upgrade falco falcosecurity/falco -n falco --reuse-values \
  --reset-then-reuse-values \
  --set customRules=null \
  --set falcosidekick.config.webhook.address=""
```

## Azure equivalent

**Microsoft Defender for Containers** uses a similar eBPF agent and ships managed rules. The trade-off:

- Defender: Azure-native, integrated with Sentinel and Defender XDR, paid per node-hour
- Falco: open-source, runs anywhere, free, but you own rule tuning and routing

Production AKS clusters commonly run both — Defender for managed coverage, Falco for custom rules that capture workload-specific behavior the generic rule set wouldn't catch.
