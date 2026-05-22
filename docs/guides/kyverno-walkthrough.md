# Kyverno Walkthrough

A five-stage guide to using Kyverno as a Kubernetes policy engine — from passively auditing existing workloads to actively rejecting bad ones to silently mutating them into compliance.

Prerequisites:

```bash
./aks-lab feature enable kyverno
kubectl get pods -n kyverno     # confirm all four controllers Running
kubectl get clusterpolicies     # the three sample policies should be visible
```

---

## Stage 1 — Audit existing workloads

**Goal:** see what the lab is currently violating without changing anything.

The three sample policies all start in `Audit` mode, so existing pods are scanned but not blocked. The `background-controller` and `reports-controller` produce a `PolicyReport` per namespace and a `ClusterPolicyReport` per cluster-scoped resource.

```bash
# Cluster-wide violation summary
kubectl get clusterpolicyreport -o custom-columns=NAME:.metadata.name,PASS:.summary.pass,FAIL:.summary.fail,WARN:.summary.warn

# Per-namespace violations
kubectl get policyreport -A

# Drill into one failing report
kubectl describe policyreport -n monitoring | head -60
```

Expect a healthy stack of "FAIL" results from monitoring and other charts that don't include `app.kubernetes.io/owner` labels — those are realistic findings, not test data.

**What you learn:** audit mode is the right starting state. Roll a policy out as `Audit`, observe the reports for a week, then promote to `Enforce` once you've fixed the violations.

---

## Stage 2 — Promote one policy to Enforce

**Goal:** see admission rejection in action.

```bash
# Flip disallow-latest-tag from Audit to Enforce
kubectl patch clusterpolicy disallow-latest-tag --type=merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'

# Try to create an offending pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kyverno-test-bad
  namespace: default
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
# Expect: error from server (Forbidden): admission webhook "validate.kyverno.svc-fail" denied the request
```

The rejection message comes straight from the policy's `validate.message`. Production teams use that message as the user-facing "why was my deploy rejected" answer, so it's worth writing well.

```bash
# Same pod with a pinned tag — should be accepted
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kyverno-test-good
  namespace: default
spec:
  containers:
    - name: app
      image: nginx:1.27
EOF

kubectl delete pod kyverno-test-good -n default
```

**What you learn:** `Enforce` is binary at admission. There is no grace period — fix violations before the flip.

---

## Stage 3 — Write a mutating policy

**Goal:** make Kyverno silently rewrite incoming resources instead of rejecting them.

A common production pattern: rewrite `image: <repo>/<image>` to `image: yourorg.azurecr.io/<repo>/<image>` so every cluster workload pulls from your internal ACR even if developers forget to specify it.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-owner-label
spec:
  background: false      # mutations don't apply retroactively
  rules:
    - name: default-owner-label
      match:
        any:
          - resources:
              kinds: [Deployment, StatefulSet]
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              app.kubernetes.io/owner: "unassigned"
EOF

# Create a deployment that omits the owner label
kubectl create deployment kyverno-mut-test --image=nginx:1.27 -n default

# Inspect — the owner label was added by Kyverno on admission
kubectl get deployment kyverno-mut-test -n default -o jsonpath='{.metadata.labels}' | jq

kubectl delete deployment kyverno-mut-test -n default
```

**What you learn:** mutating policies are the "guard rails without complaints" tool. Use validate when the user must fix the resource; use mutate when the policy can fix it for them.

---

## Stage 4 — Generate a default NetworkPolicy per namespace

**Goal:** see Kyverno's `generate` rule, which creates resources reactively.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-deny-per-namespace
spec:
  background: true
  rules:
    - name: generate-default-deny
      match:
        any:
          - resources:
              kinds: [Namespace]
              names: ["team-*"]
      generate:
        kind: NetworkPolicy
        apiVersion: networking.k8s.io/v1
        name: default-deny-ingress
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes: [Ingress]
EOF

# Create a matching namespace
kubectl create namespace team-demo

# Confirm Kyverno generated the NetworkPolicy
kubectl get networkpolicy -n team-demo

kubectl delete namespace team-demo
```

`synchronize: true` means Kyverno will recreate the NetworkPolicy if someone deletes it. That's the difference between "we generated this once" and "we own this resource".

**What you learn:** generate rules turn Kyverno into a low-rent operator — you describe what should exist and Kyverno keeps it there.

---

## Stage 5 — Verify image signatures (optional, requires cosign)

**Goal:** see `verifyImages` reject unsigned containers.

This stage requires the cluster to reach `cgr.dev` or wherever your signed image lives. In a fully offline lab, skip to Cleanup.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-cosign
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: ["signed-test"]
      verifyImages:
        - imageReferences: ["ghcr.io/sigstore/sample-honk*"]
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/sigstore/cosign/.github/workflows/*"
                    issuer: "https://token.actions.githubusercontent.com"
EOF
```

Kyverno fetches the image, looks up the cosign signature, and validates the keyless attestor (Fulcio cert with the expected subject and OIDC issuer).

**What you learn:** image verification is policy, not a separate tool. The supply-chain check happens at admission alongside the regular validation.

---

## Cleanup

```bash
kubectl delete clusterpolicy require-signed-images add-owner-label default-deny-per-namespace 2>/dev/null

# Reset the sample policy back to audit
kubectl patch clusterpolicy disallow-latest-tag --type=merge \
  -p '{"spec":{"validationFailureAction":"Audit"}}'
```

## Azure equivalent

Azure Policy for Kubernetes (Gatekeeper) does the same job but uses OPA/Rego. The two main ergonomic advantages of Kyverno: policies are written as plain Kubernetes YAML (no second language to learn) and image mutation/verification are first-class. Gatekeeper has the advantage of being integrated with Azure Policy's compliance reporting.

In production it's common to run both: Azure Policy for compliance reporting, Kyverno for day-to-day platform guardrails and mutations.
