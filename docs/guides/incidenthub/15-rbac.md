# Stage 15 — ServiceAccount, Role, RoleBinding

**Exam focus:** CKA — RBAC, ClusterRoles vs Roles. CKS — least privilege, audit, dangerous verbs.

**Goal:** give IncidentHub Pods a *dedicated* ServiceAccount with only the permissions they actually need. Stop using `default`.

---

## Why not just use `default`?

Every namespace has a `default` ServiceAccount. Pods that don't set `serviceAccountName` get it. By default it has *no* API permissions — but in many clusters someone has bound `cluster-admin` to it for convenience, and now every pod is god.

Always:

1. Create a ServiceAccount per workload.
2. Bind it to a minimal Role/ClusterRole.
3. Set `serviceAccountName` in the Pod spec.

## ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: incidenthub
  namespace: incidenthub
automountServiceAccountToken: true   # default; needed for the Vault auth flow
```

`automountServiceAccountToken: false` is the right default if a Pod doesn't need to talk to the API. For IncidentHub we leave it on because Vault Agent uses the SA JWT.

## Role + RoleBinding

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: incidenthub-reader
  namespace: incidenthub
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: incidenthub-reader
  namespace: incidenthub
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: incidenthub-reader }
subjects:
  - kind: ServiceAccount
    name: incidenthub
    namespace: incidenthub
```

This Role:

- Lets the SA read configmaps and secrets *in `incidenthub` namespace only*.
- Lets it `get` and `list` Pods in the same namespace.
- Cannot create, update, delete anything. Cannot read across namespaces.

## Role vs ClusterRole

| | Role | ClusterRole |
|--|------|-------------|
| Scope | One namespace | Whole cluster, OR namespaced via RoleBinding |
| Resources | Namespaced (pods, services…) | Namespaced + cluster-scoped (nodes, pvs, namespaces…) |
| Bound by | RoleBinding | RoleBinding (one ns) OR ClusterRoleBinding (cluster) |

**Pattern:** define a ClusterRole once, bind it via RoleBinding into many namespaces. That's how you share permissions without duplicating Roles.

## CKS — dangerous verbs and resources

These deserve a code-review reflex:

| Verb / resource | Why dangerous |
|-----------------|---------------|
| `*` on `*` | Cluster-admin equivalent. |
| `create` on `pods/exec` | Run arbitrary code in any pod the binding covers. |
| `escalate`, `bind` on `(cluster)roles` | Grant yourself higher privileges. |
| `impersonate` on `users/groups/serviceaccounts` | Act as another identity. |
| `create` on `clusterrolebindings` | Self-promote. |
| `update`, `patch` on `nodes` | Disable schedulability, taint nodes. |
| `*` on `secrets` (cluster-wide) | Read every secret in every namespace. |

Audit existing bindings:

```bash
# Everyone bound to cluster-admin
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + (.subjects // [] | tostring)'

# What can my SA do?
kubectl auth can-i --as=system:serviceaccount:incidenthub:incidenthub --list -n incidenthub
```

## Wire the Pod

```yaml
spec:
  template:
    spec:
      serviceAccountName: incidenthub
      containers:
        - name: web
          # ...
```

## Try the permissions from inside

```bash
kubectl -n incidenthub exec -it deploy/incidenthub-web -c web -- /bin/bash
# inside:
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
APISERVER=https://kubernetes.default.svc

# Allowed
curl -sS --cacert $CA -H "Authorization: Bearer $TOKEN" \
  $APISERVER/api/v1/namespaces/incidenthub/pods | jq '.items[].metadata.name'

# Denied
curl -sS --cacert $CA -H "Authorization: Bearer $TOKEN" \
  $APISERVER/api/v1/namespaces/kube-system/secrets
# 403 Forbidden
```

## What you learn

- RBAC binds Subjects → Roles. Subjects can be ServiceAccounts, Users, or Groups.
- Roles are *additive only* — there's no `deny`. Restriction is achieved by *not* granting.
- ClusterRole + RoleBinding is the most common way to share role definitions cleanly.
- `kubectl auth can-i` is the fastest way to confirm a Role works as intended.

## Try this (exam-form)

```bash
# Quick imperative ServiceAccount + binding
kubectl -n incidenthub create sa incidenthub
kubectl -n incidenthub create role incidenthub-reader \
  --verb=get,list --resource=pods,configmaps,secrets
kubectl -n incidenthub create rolebinding incidenthub-reader \
  --role=incidenthub-reader --serviceaccount=incidenthub:incidenthub

# Confirm
kubectl auth can-i list pods -n incidenthub \
  --as=system:serviceaccount:incidenthub:incidenthub

# Reverse audit — who can read secrets in incidenthub?
kubectl auth can-i list secrets -n incidenthub --as=system:serviceaccount:incidenthub:default
```

Next — [Stage 16: NetworkPolicy](16-networkpolicy.md).
