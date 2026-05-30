# Exam Simulator Walkthrough

This guide covers how to use the exam-sim pod and the dashboard exam mode to practise for the CKA, CKAD, and CKS certifications. Scenarios are calibrated to killer.sh difficulty — harder than the real exam, so you build speed and confidence before sitting.

## Prerequisites

Enable the exam-sim pod:

```bash
./aks-lab feature enable exam-sim
```

Then connect:

```bash
ssh aks-exam-sim          # shortcut added by setup-lab.sh
# or
ssh -p 2224 root@localhost
```

The MOTD shows your available contexts, aliases, and exam tips.

---

## Part 1: Shell setup drills

Run these every time you open a new exam terminal to build the habit.

### 1.1 Check available contexts

```bash
kubectl config get-contexts
```

Expected output: `k8s`, `wk8s`, `bk8s`, `ek8s`, `ik8s` all listed.

### 1.2 Context switching

```bash
kx k8s        # switch to k8s context
kx bk8s       # switch to bk8s
kx ek8s       # switch to ek8s
kx k8s        # back to k8s
```

Practice until `kx <name>` is automatic — forgetting to switch context is one of the most common failure modes in the real exam.

### 1.3 Namespace shortcut

```bash
kn kube-system    # set default namespace
k get pods        # now lists kube-system pods without -n flag
kn default        # reset
```

### 1.4 YAML generation speed drill

```bash
# Pod
k run nginx --image=nginx:stable $do

# Deployment
k create deployment web --image=nginx:stable --replicas=3 $do

# Service
k expose deployment web --port=80 $do

# Job
k create job cleanup --image=busybox -- echo done $do

# CronJob
k create cronjob cleanup --image=busybox --schedule='*/5 * * * *' -- echo done $do
```

Pipe any of these to `kubectl apply -f -` to create the resource immediately:

```bash
k run nginx --image=nginx:stable $do | k apply -f -
```

### 1.5 Force delete

```bash
k delete pod stuck-pod $now
```

### 1.6 etcdctl (CKA/CKS)

```bash
# Verify etcdctl works (ETCDCTL_API=3 is set by default)
etcdctl version

# Snapshot (you need the TLS flags in the real exam — see Stage 25 of the IncidentHub guide)
ETCDCTL_API=3 etcdctl snapshot save /tmp/snap.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

---

## Part 2: tmux pane layout

In the real exam you have multiple terminal windows. In exam-sim, use tmux panes:

```bash
tmux                    # start session
# Ctrl+b |             # vertical split (right pane = scratch)
# Ctrl+b arrow         # navigate between panes
```

**Recommended layout:**

| Left pane | Right pane |
|-----------|-----------|
| kubectl commands | Scratch notepad |

Use the right pane as a notepad:

```bash
vim ~/notes.txt         # keep common YAML snippets here
```

---

## Part 3: Dashboard exam mode

The lab dashboard at `http://localhost:9997` has a built-in exam mode.

1. Open the dashboard → scroll to **Exam Mode**
2. Select track (CKA / CKAD / CKS) and duration
3. Click **Start Exam** — a random set of scenarios is selected with a countdown timer
4. For MCQ questions: select your answer directly in the dashboard
5. For task questions: complete the task in the exam-sim terminal, then come back and click **Submit**
6. When done (or time runs out), the exam auto-submits and shows your score report

**Pass threshold:** 66% (matches the real exam). Target 90%+ before booking the real exam.

---

## Part 4: Exam track practice tips

### CKA (Certified Kubernetes Administrator)

High-value topics to drill (30% of the real exam is troubleshooting):

```bash
# Drain and cordon a node
k cordon aks-lab-m02
k drain aks-lab-m02 --ignore-daemonsets --delete-emptydir-data
k uncordon aks-lab-m02

# Check component statuses
k get componentstatuses
k get nodes

# Certificate expiry (in real exam: kubeadm certs check-expiration)
# etcd backup (see etcdctl section above)
# Cluster upgrade: kubeadm upgrade plan → kubeadm upgrade apply
```

### CKAD (Certified Kubernetes Application Developer)

```bash
# Multi-container pod (sidecar pattern)
k run multi --image=nginx $do > pod.yaml
# Edit pod.yaml to add a second container, then apply

# ConfigMap → env vars
k create configmap app-cfg --from-literal=ENV=prod $do | k apply -f -
k set env deployment/web --from=configmap/app-cfg

# Liveness / readiness probes
k run probed --image=nginx $do > pod.yaml
# Add livenessProbe and readinessProbe sections, then apply

# HPA
k autoscale deployment web --cpu-percent=70 --min=1 --max=5
```

### CKS (Certified Kubernetes Security Specialist)

```bash
# Pod security context
k run secure --image=nginx $do > pod.yaml
# Add securityContext: runAsUser, readOnlyRootFilesystem, capabilities.drop

# NetworkPolicy: default deny
cat <<EOF | k apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: target-ns
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF

# PSA label
k label namespace target-ns pod-security.kubernetes.io/enforce=restricted

# Trivy image scan
trivy image --severity CRITICAL nginx:1.21

# RBAC audit
k auth can-i --list --as=system:serviceaccount:myns:mysa
```

---

## Part 5: Killer.sh integration

[Killer.sh](https://killer.sh) is widely regarded as the best paid exam simulator for CKA, CKAD, and CKS. You receive **2 free 36-hour sessions** with every Linux Foundation exam voucher.

**How to use killer.sh alongside this lab:**

1. Work through scenarios in this lab (dashboard exam mode) until you can score 80%+ consistently
2. ~2 weeks before the real exam, start your first killer.sh session
3. Aim for 90%+ on killer.sh **with time remaining** — not just a pass
4. ~2 days before the exam, use your second killer.sh attempt as a final confidence check

**Key difference:** The scenarios in this lab are calibrated to the same difficulty as killer.sh — harder than the real exam. If you can pass here, you'll pass in the real exam.

**Allowed documentation in the real exam:**

- [kubernetes.io/docs](https://kubernetes.io/docs)
- [kubernetes.io/blog](https://kubernetes.io/blog)
- [helm.sh/docs](https://helm.sh/docs) (Helm tasks only)
- CKS also allows: Falco docs, etcd docs, Cilium docs, Istio docs

---

## Part 6: vim cheat sheet for the exam

```
i          — enter insert mode (INSERT key is disabled in the real exam)
Esc        — exit insert mode
:wq        — save and quit
:q!        — quit without saving
dd         — delete line
yy         — yank (copy) line
p          — paste below
gg         — go to top
G          — go to bottom
/pattern   — search
n          — next match
:set paste — enable paste mode (already set in .vimrc)
```

---

## Further reading

- [docs/services/exam-sim.md](../services/exam-sim.md) — pod reference, tools list, context table
- [docs/guides/incidenthub/](incidenthub/) — 26-stage walkthrough covering CKAD/CKA/CKS topics
- [scenarios/SCHEMA.md](../../scenarios/SCHEMA.md) — how to add your own scenarios
