# Stage 17 — Pod Security Standards + SecurityContext

**Exam focus:** CKS — PSS, SecurityContext, seccomp, capabilities.

**Goal:** make the `incidenthub` namespace refuse pods that don't meet the *restricted* Pod Security Standard. Drop capabilities, run as non-root, mount a read-only root filesystem.

---

## Pod Security Standards in three lines

| Profile | Designed for |
|---------|--------------|
| **privileged** | Cluster-trusted workloads (CNI, kube-proxy). No restrictions. |
| **baseline** | Common easy-to-violate misconfigs are blocked. Reasonable for most apps. |
| **restricted** | Hardened defaults — non-root, dropped capabilities, no privilege escalation, seccomp. |

PSS is enforced by **namespace label**, by the in-tree admission plugin:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: incidenthub
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

- `enforce` — bad pods are rejected at admission.
- `audit` — bad pods are accepted but flagged in the audit log.
- `warn` — kubectl prints warnings.

```bash
kubectl label ns incidenthub pod-security.kubernetes.io/enforce=restricted --overwrite
```

## The SecurityContext IncidentHub needs to pass *restricted*

```yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: web
          image: ...
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: tmp
          emptyDir: {}
```

Field by field:

| Field | What it does |
|-------|--------------|
| `runAsNonRoot: true` | Kubelet refuses to start a container that runs as UID 0. Defence-in-depth even if the image was wrong. |
| `runAsUser: 10001` | Use this UID. The Dockerfile already does, but explicit > implicit. |
| `seccompProfile: { type: RuntimeDefault }` | Apply Docker/containerd's default seccomp filter — blocks ~50 dangerous syscalls. *Required* by restricted PSS. |
| `allowPrivilegeEscalation: false` | Prevents `setuid` binaries from gaining capabilities. |
| `readOnlyRootFilesystem: true` | `/` is read-only. Any writable path needs an explicit `emptyDir`. Stops post-compromise persistence. |
| `capabilities.drop: ["ALL"]` | Linux capabilities — drop everything. (Add back via `add:` only what you really need.) |

`readOnlyRootFilesystem: true` is why we mount `emptyDir` at `/tmp` — ASP.NET writes temp files there.

## Apply, watch admission

```bash
kubectl apply -f web-deployment.yaml
# If the spec doesn't comply, kubectl prints something like:
# Error from server (Forbidden): error when creating "...": pods "..." is forbidden:
#   violates PodSecurity "restricted:latest":
#   allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true

# When it passes
kubectl -n incidenthub get pods
# Running
```

## Seccomp custom profiles

For tighter control than `RuntimeDefault`:

```yaml
        seccompProfile:
          type: Localhost
          localhostProfile: profiles/incidenthub.json
```

The JSON profile lives in `/var/lib/kubelet/seccomp/profiles/incidenthub.json` on every node. Define a strict allowlist; CIS Kubernetes Benchmark covers the common syscall sets.

## AppArmor

If your nodes run AppArmor (Ubuntu, Debian), annotate the Pod to load a profile:

```yaml
metadata:
  annotations:
    container.apparmor.security.beta.kubernetes.io/web: runtime/default
```

`runtime/default` is the containerd default. Custom profiles work the same way as seccomp — file on disk, referenced by name.

## What you learn

- PSS is enforced **at namespace admission time**, not at runtime. A non-compliant pod is rejected before it ever schedules.
- SecurityContext lives at *two* levels — Pod-wide (`spec.securityContext`) and per-container. Per-container overrides Pod-wide.
- *Restricted* is the right default for app workloads. *Baseline* is fine for legacy. *Privileged* is for trusted infrastructure only.
- `readOnlyRootFilesystem: true` is one of the highest-value/lowest-effort hardenings. It's how you stop a webshell from writing to disk.

## Try this (exam-form)

```bash
# What's the namespace currently enforcing?
kubectl get ns incidenthub --show-labels | grep pod-security

# Dry-run audit a manifest against a profile
kubectl apply --dry-run=server -f bad-pod.yaml
# verbose violation report

# Generate a SecurityContext that meets restricted, for a new Deployment
kubectl create deploy demo --image=nginx --dry-run=client -o yaml > demo.yaml
# then add the securityContext block

# List every pod NOT meeting restricted in a namespace
kubectl label ns incidenthub pod-security.kubernetes.io/audit=restricted --overwrite
# then check the API server audit log for `level: "audit"` PodSecurity entries
```

Next — [Stage 18: HPA + KEDA autoscaling](18-autoscaling.md).
