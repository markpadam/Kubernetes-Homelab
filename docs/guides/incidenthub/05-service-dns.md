# Stage 05 — Service & cluster DNS

**Exam focus:** CKAD/CKA — Service types, kube-dns / CoreDNS resolution, endpoints.

**Goal:** front the Deployment with a Service so other Pods can reach it by name. Understand how cluster DNS turns that name into an IP.

---

## Why a Service

Pod IPs are ephemeral — a rollout, a node failure, or a scale operation gives every Pod a new IP. A Service is a stable virtual IP (a *cluster IP*) that load-balances across whatever Pods currently match its selector.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: incidenthub-web
  namespace: incidenthub
spec:
  selector: { app: incidenthub, component: web }
  ports:
    - port: 80          # the port on the ClusterIP
      targetPort: 8080  # the port on the Pod
      protocol: TCP
```

```bash
kubectl apply -f service.yaml
kubectl -n incidenthub get svc,endpoints
```

The `Endpoints` (or `EndpointSlices` on newer versions) object lists the Pod IPs currently behind the Service. If a Pod fails its readiness probe (stage 07), it's removed from the Endpoints list — that's how Services exclude unhealthy backends.

## Service types

| Type | Visible from | Used for |
|------|--------------|----------|
| **ClusterIP** (default) | Inside the cluster only | Pod-to-pod traffic. The norm. |
| **NodePort** | A high port on every node's IP | Quick external access without an Ingress (port 30000–32767). |
| **LoadBalancer** | Cloud LB on a public IP | Production external. In Minikube it stays `<pending>`. |
| **ExternalName** | DNS CNAME to an external host | "Service" that maps to e.g. an Azure private endpoint. |
| **Headless** (`clusterIP: None`) | Pods resolve directly via DNS | StatefulSets — each Pod has its own DNS name. |

For IncidentHub web we use ClusterIP. Stage 12 adds an Ingress in front for external access.

## Cluster DNS

CoreDNS resolves three forms of name inside the cluster:

```text
<svc>.<ns>.svc.cluster.local        # canonical FQDN
<svc>.<ns>                          # same — short form
<svc>                               # only resolves in the same namespace
```

Test it from a debug pod:

```bash
kubectl -n incidenthub run dns-test --rm -it --image=busybox -- sh

#  inside the pod:
nslookup incidenthub-web
# Address: 10.96.x.y         <- the ClusterIP

nslookup incidenthub-web.incidenthub.svc.cluster.local
# same

nslookup mssql.azure-sql.svc.cluster.local
# Address: 10.96.x.z         <- this is what your SQL conn string resolves to
```

The CoreDNS config (`kubectl -n kube-system get cm coredns -o yaml`) shows the chain — local cluster names first, then forward to upstream. In this lab CoreDNS also forwards `corp.internal` to the Samba AD VM (see [dns-walkthrough.md](../dns-walkthrough.md)).

## Endpoints — the truth behind a Service

```bash
kubectl -n incidenthub describe svc incidenthub-web
# Endpoints: 10.244.0.21:8080,10.244.0.22:8080

kubectl -n incidenthub get endpointslices -l kubernetes.io/service-name=incidenthub-web
```

If `Endpoints` is empty, the Service selector doesn't match any Pod *or* no Pod is Ready. This is one of the top three things to check when "the Service doesn't work."

## Headless Services

If you want each Pod individually addressable by DNS — e.g. for a StatefulSet — set `clusterIP: None`:

```yaml
spec:
  clusterIP: None
  selector: { app: incidenthub, component: web }
```

DNS then returns *one A record per Pod* instead of one for the Service. You won't use this for IncidentHub itself, but it's how you'd reach individual SQL Server replicas behind a StatefulSet.

## NetworkPolicy preview

Without NetworkPolicy (stage 16), all Pods can hit all Services. The Service stays reachable even from other namespaces. NetworkPolicy is what locks that down at L3/L4 — a Service object alone doesn't restrict anything.

## What you learn

- Services are virtual IPs implemented by kube-proxy (iptables or IPVS).
- Pods discover Services via DNS. The most reliable form is the FQDN — `<svc>.<ns>.svc.cluster.local`.
- An empty Endpoints/EndpointSlice is the most common cause of "Service isn't routing."
- kube-dns / CoreDNS chain: cluster local → forwarders. The lab's CoreDNS is patched to forward `corp.internal` to the AD VM.

## Try this (exam-form)

```bash
# Create a Service imperatively from a Deployment
kubectl -n incidenthub expose deploy/incidenthub-web --port=80 --target-port=8080

# See which pods the Service is selecting right now
kubectl -n incidenthub get pods -l app=incidenthub,component=web

# Curl the ClusterIP from inside the cluster
kubectl -n incidenthub run curl --rm -it --image=curlimages/curl -- \
  curl -sf http://incidenthub-web/healthz

# Diagnose: Service exists but no traffic flows
kubectl -n incidenthub get endpointslices
kubectl -n incidenthub describe svc incidenthub-web  # check selector matches pod labels
```

Next — [Stage 06: ConfigMap & Secret](06-config-secrets.md).
