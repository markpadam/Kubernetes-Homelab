# IncidentHub Walkthrough

A 26-stage master walkthrough that builds an ASP.NET Core incident-reporting app (IncidentHub) while learning the cluster service by service. Each stage maps to one or more topics from the CKAD, CKA, and CKS exams.

Start at [00-overview.md](00-overview.md).

| Stage | Topic | Primary exam |
|-------|-------|--------------|
| [00](00-overview.md) | App architecture & prerequisites | — |
| [01](01-dotnet-local.md) | Build & run .NET locally | — |
| [02](02-containerise.md) | Dockerise + push to in-cluster registry | CKAD/CKS |
| [03](03-pod.md) | First Pod — lifecycle, exec, logs | CKAD |
| [04](04-deployment.md) | Deployment, rolling updates, rollback | CKAD |
| [05](05-service-dns.md) | Service + kube-dns | CKAD/CKA |
| [06](06-config-secrets.md) | ConfigMap + Secret | CKAD |
| [07](07-probes-resources.md) | Probes, requests/limits, QoS | CKAD/CKA |
| [08](08-azure-sql.md) | Azure SQL — persistent state | CKAD |
| [09](09-azurite-blob.md) | Azurite — blob attachments | CKAD |
| [10](10-service-bus.md) | Service Bus — async worker | CKAD |
| [11](11-cosmos-db.md) | Cosmos DB — search projection | CKAD |
| [12](12-ingress-tls.md) | Ingress + cert-manager TLS | CKAD/CKS |
| [13](13-auth.md) | OAuth2 Proxy + Dex SSO | CKS |
| [14](14-vault.md) | Vault Agent secret injection | CKS |
| [15](15-rbac.md) | ServiceAccount, Role, RoleBinding | CKA/CKS |
| [16](16-networkpolicy.md) | NetworkPolicy default-deny | CKS |
| [17](17-pod-security.md) | PSS + SecurityContext + seccomp | CKS |
| [18](18-autoscaling.md) | HPA + KEDA | CKA/CKAD |
| [19](19-scheduling.md) | nodeSelector, taints, affinity | CKA |
| [20](20-jobs-cronjobs.md) | Job + CronJob | CKAD |
| [21](21-argo-workflows.md) | Argo Workflows nightly archive | CKAD |
| [22](22-flux-gitops.md) | Flux GitOps delivery | CKAD/CKA |
| [23](23-supply-chain.md) | Trivy + Cosign | CKS |
| [24](24-observability.md) | Logs, events, Dashboard, Rancher | CKA |
| [25](25-dr.md) | etcd snapshot & restore | CKA |

The app code lives in [src/incidenthub/](../../../src/incidenthub/). The converged Helm chart is at [helm/incidenthub/](../../../helm/incidenthub/).
