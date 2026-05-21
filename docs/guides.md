# Lab Guides

Progressive walkthroughs for every major system in the lab. Each guide is structured as self-contained stages — work through them in order or jump to any stage that interests you.

---

## Recommended order

The guides below are sequenced so that each one builds on concepts introduced earlier. If you're working through the lab for the first time, follow this order.

| # | Guide | What you learn |
|---|-------|----------------|
| 1 | [TaskFlow Walkthrough](guides/taskflow-walkthrough.md) | Core Kubernetes patterns: deployments, services, ingress, PostgreSQL persistence, and the three-tier web app model. Start here to get something running and visible before diving into infrastructure. |
| 2 | [DNS Walkthrough](guides/dns-walkthrough.md) | How CoreDNS and Bind9 create a split-brain DNS architecture that mirrors Azure enterprise DNS. Foundation for everything else — private link names, service discovery, and ADDS simulation all depend on this. |
| 3 | [Flux Walkthrough](guides/flux-walkthrough.md) | How GitOps keeps the cluster in sync with this repository. Covers the reconciliation loop, Kustomization layering, pruning, and how `./aks-lab feature` enables optional components by committing to git. |
| 4 | [Container Registry Walkthrough](guides/container-registry-walkthrough.md) | The in-cluster OCI registry — pushing and pulling images, the registry REST API, private link DNS simulation, and how Flux pulls images from it during deployment. |
| 5 | [Vault Walkthrough](guides/vault-walkthrough.md) | HashiCorp Vault as a secret store. KV v2 secrets, policies, Kubernetes auth backend, and the zero-static-credential pattern where pods authenticate with their service account token. |
| 6 | [Authentication Walkthrough](guides/auth-walkthrough.md) | The full SSO chain: SambaAD LDAP → Dex OIDC → OAuth2 Proxy → NGINX ingress. Includes Active Directory basics, Kerberos tickets, domain join, and JWT decoding. |
| 7 | [Azurite Walkthrough](guides/azurite-walkthrough.md) | Azure Blob, Queue, and Table Storage emulation. Connection string anatomy, each storage API, private link DNS, and the Blob Explorer integration. |
| 8 | [Azure SQL Walkthrough](guides/azure-sql-walkthrough.md) | Azure SQL Edge as a SQL Server emulator. T-SQL basics, the TDS wire protocol, data persistence, and private link DNS for Azure SDK connection strings. |
| 9 | [Service Bus Walkthrough](guides/service-bus-walkthrough.md) | AMQP 1.0 messaging with the Azure Service Bus emulator. Queues, topics, subscriptions, and how the emulator uses SQL Server for state storage. |
| 10 | [Cosmos DB Walkthrough](guides/cosmos-db-walkthrough.md) | Azure Cosmos DB NoSQL API emulation. The Data Explorer UI, CRUD operations, SDK connection strings, and multi-region endpoint simulation. |
| 11 | [Rancher Walkthrough](guides/rancher-walkthrough.md) | Optional. Cluster management UI with workload explorer, Helm marketplace, browser-based kubectl shell, and Fleet GitOps engine. Resource-heavy — enable only when you want the visual layer. |
| 12 | [Postman & the Kubernetes API Walkthrough](guides/postman-kubernetes-api-walkthrough.md) | Call the Kubernetes REST API directly from Postman. ServiceAccount auth, CA certificate setup, health endpoints, API discovery, querying pods/deployments/services, reading logs, and understanding RBAC via SelfSubjectAccessReview. |
| 13 | [Argo Workflows Walkthrough](guides/argo-workflows-walkthrough.md) | Optional. Kubernetes-native workflow orchestration — running steps as pods, building DAG pipelines, reusing WorkflowTemplates, and the Argo Server UI. Azure equivalent of Logic Apps / Container Apps Jobs. |

---

## Guide format

Every guide follows the same structure:

- **Goal** — what you will understand by the end of the stage
- **Commands** — copy-paste commands with expected output noted
- **Azure equivalent** — how the lab component maps to a real Azure service
- **What you learn** — the takeaway in plain language
- **Quick reference** — a table of the most-used commands, at the end

---

## Prerequisites

Before starting, the lab must be running (`./aks-lab setup`). The [TaskFlow Walkthrough](guides/taskflow-walkthrough.md) is the best first check that everything is up.

The `toolbox` pod is used in many guides as a network debugging base:

```bash
kubectl exec -it -n toolbox deploy/toolbox -- bash
```

Enable it if not already running:

```bash
./aks-lab feature enable toolbox
```
