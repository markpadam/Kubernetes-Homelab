# IncidentHub — Master Learning Walkthrough

A progressive, 26-stage guide that builds **IncidentHub** — a corporate incident-reporting web app — while learning the cluster service by service. Each stage is self-contained and maps to one or more topics from the CKAD, CKA, and CKS exams.

---

## The app

**IncidentHub** is an ASP.NET Core 8 portal where employees file incident reports against `corp.internal`. By the end of the walkthrough it consists of:

- **Web** — Razor Pages frontend, lists and files incidents
- **Worker** — background service consuming events from Service Bus
- **Migrator** — one-shot Job that creates the SQL schema

…and uses these cluster services along the way:

| Service | Role in IncidentHub |
|---------|---------------------|
| Container Registry | Image source for all three components |
| Azure SQL (mssql emulator) | Relational store — Incidents table |
| Azurite | Blob storage for incident attachments |
| Service Bus | `incident-created` queue between web and worker |
| Cosmos DB | Denormalised search projection |
| cert-manager + Vault PKI | TLS for the ingress |
| NGINX Ingress | Public entry point at `https://incidenthub.aks-lab.local` |
| OAuth2 Proxy + Dex + SambaAD | SSO — only AD users can file incidents |
| Vault | KV v2 holds connection strings; Vault Agent injects them at pod start |
| KEDA | Scales the worker on Service Bus queue depth |
| HPA | Scales the web on CPU |
| Argo Workflows | Nightly "archive resolved incidents" workflow |
| Flux | GitOps delivery from this repo |
| Kubernetes Dashboard, Rancher | Observability |

## Exam coverage

| Exam | Stages covering core topics |
|------|-----------------------------|
| **CKAD** (developer) | 03 pods · 04 deployments · 05 services · 06 configmaps/secrets · 07 probes · 08–11 backing stores · 12 ingress · 14 vault · 18 HPA · 20 jobs/cronjobs · 21 argo |
| **CKA** (administrator) | 05 cluster DNS · 07 QoS · 15 RBAC · 18 HPA · 19 scheduling · 22 GitOps drift · 24 troubleshooting · 25 etcd backup |
| **CKS** (security) | 02 image hygiene · 12 TLS · 13 ingress auth · 14 secrets at rest · 15 least-priv RBAC · 16 NetworkPolicy · 17 PSS + seccomp · 23 supply chain (Trivy + Cosign) |

## Stage map

```text
 00 ─── overview (you are here)
 01 ─── build & run the .NET app locally
 02 ─── containerise + push to in-cluster registry
 03 ─── first pod                              ← CKAD
 04 ─── deployment, rolling updates, rollback  ← CKAD
 05 ─── service + cluster DNS                  ← CKAD/CKA
 06 ─── ConfigMap + Secret                     ← CKAD
 07 ─── probes, resources, QoS                 ← CKAD/CKA
 08 ─── Azure SQL — persistent state           ← CKAD
 09 ─── Azurite — blob attachments             ← CKAD
 10 ─── Service Bus — async worker             ← CKAD
 11 ─── Cosmos DB — search projection          ← CKAD
 12 ─── Ingress + cert-manager TLS             ← CKAD/CKS
 13 ─── OAuth2 Proxy + Dex auth                ← CKS
 14 ─── Vault Agent injection                  ← CKS
 15 ─── ServiceAccount, Role, RoleBinding      ← CKA/CKS
 16 ─── NetworkPolicy default-deny + allowlist ← CKS
 17 ─── Pod Security Standards + seccomp       ← CKS
 18 ─── HPA + KEDA                             ← CKA/CKAD
 19 ─── nodeSelector, taints, affinity         ← CKA
 20 ─── Job + CronJob                          ← CKAD
 21 ─── Argo Workflows nightly archive         ← CKAD
 22 ─── Flux GitOps delivery                   ← CKAD/CKA
 23 ─── Supply chain: Trivy + Cosign           ← CKS
 24 ─── Logs, events, Dashboard, Rancher       ← CKA
 25 ─── etcd snapshot & restore                ← CKA
```

## How to use this guide

- **Run the lab first** — `./setup-lab.sh`. Most stages assume the standard set of services is up.
- **One stage at a time** — each builds on the previous and finishes with a clean cluster state you can leave running.
- **Two artefacts per stage** — raw YAML you `kubectl apply -f -` (learning), and the equivalent block in `helm/incidenthub/` (final state). The Helm chart is the production-style assembly of every stage's idea.
- **Source code** — lives in [src/incidenthub/](../../../src/incidenthub/). You don't need to write code; the source is already there. Read it as you go.
- **Cheat-sheet** — every stage ends with a "Try this" panel of imperative `kubectl` commands you'd use in the exam.

## Prerequisites

```bash
# Required services for most stages
./scripts/lab-feature.sh enable vault
./scripts/lab-feature.sh enable cert-manager
./scripts/lab-feature.sh enable azurite
./scripts/lab-feature.sh enable azure-sql
./scripts/lab-feature.sh enable service-bus
./scripts/lab-feature.sh enable cosmos-db
./scripts/lab-feature.sh enable container-registry

# Optional — needed in later stages
./scripts/lab-feature.sh enable dex
./scripts/lab-feature.sh enable oauth2-proxy
./scripts/lab-feature.sh enable keda
./scripts/lab-feature.sh enable argo-workflows
./scripts/lab-feature.sh enable flux
```

## What you ship

A running, secured, observed, autoscaling, GitOps-delivered .NET application that exercises every major Kubernetes primitive on the exam. When you finish, you can confidently:

- Explain pod lifecycle, Deployment rollout semantics, and probe types
- Wire an app to four different backing stores with secrets injected at runtime
- Restrict pods with PSS, NetworkPolicy, RBAC, and SecurityContext
- Scale workloads on CPU and queue depth
- Diagnose a broken pod from `kubectl` alone
- Back up and restore etcd

Onwards — [Stage 01: build & run locally](01-dotnet-local.md).
