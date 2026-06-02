# AKS Lab — Service Documentation

Each service running in the cluster has its own doc below.

## Identity & Authentication

| Doc | Location | Purpose |
|-----|----------|---------|
| [samba-ad.md](services/samba-ad.md) | Lima VM | Samba 4 Active Directory DC — simulates on-prem ADDS |
| [dex.md](services/dex.md) | `dex` namespace | OIDC identity provider — bridges AD LDAP to OAuth2 |
| [oauth2-proxy.md](services/oauth2-proxy.md) | `oauth2-proxy` namespace | Ingress authentication gateway — protects all web services |
| [corp-client.md](tools/corp-client.md) | Lima VM | Domain-joined Ubuntu VM — simulates a corporate laptop |
| [auth-walkthrough.md](guides/auth-walkthrough.md) | — | Nine-stage guide to the full SSO authentication chain |

## Monitoring & Observability

Installed by default. Azure equivalent: Azure Monitor + Azure Managed Grafana + Azure Monitor Alerts.

| Doc | Namespace | Purpose |
|-----|-----------|---------|
| [monitoring.md](services/monitoring.md) | `monitoring` | Stack overview — kube-prometheus-stack, access, credentials, Azure mapping |
| [prometheus.md](services/prometheus.md) | `monitoring` | Scrape pipeline, ServiceMonitors, PromQL quick reference, retention |
| [grafana.md](services/grafana.md) | `monitoring` | Dashboards, datasources, provisioning custom boards via ConfigMap |
| [alertmanager.md](services/alertmanager.md) | `monitoring` | Alert routing, pre-loaded rules, adding Slack / webhook receivers |

## Shared Infrastructure

| Doc | Namespace | Purpose |
|-----|-----------|---------|
| [dns.md](services/dns.md) | `dns-lab` | Bind9 + CoreDNS — simulates ADDS split-brain DNS |
| [vault.md](services/vault.md) | Mac host | HashiCorp Vault dev server — simulates Azure Key Vault + private CA |
| [cert-manager.md](services/cert-manager.md) | `cert-manager` | TLS certificate lifecycle — issues, renews and revokes HTTPS certs via Vault PKI |
| [kubernetes-dashboard.md](services/kubernetes-dashboard.md) | `kubernetes-dashboard` | Official Kubernetes web UI — cluster explorer, workloads, logs |
| [toolbox.md](tools/toolbox.md) | `toolbox` | Ubuntu SSH pod for in-cluster debugging |

## Production AKS parity (optional)

Mirrors the tools used in production AKS. All optional — `./aks-lab feature enable <id>`.

| Doc | Namespace | Production AKS role |
|-----|-----------|---------------------|
| [reflector.md](services/reflector.md) | `reflector` | Cross-namespace Secret / ConfigMap mirroring (no Azure-native peer) |
| [kyverno.md](services/kyverno.md) | `kyverno` | Policy engine (alternative to Azure Policy for Kubernetes / Gatekeeper) |
| [falco.md](services/falco.md) | `falco` | Runtime security (open-source alternative to Microsoft Defender for Containers) |
| [istio.md](services/istio.md) | `istio-system` | Service mesh — mTLS, traffic shifting, L7 authorization (upstream of AKS Istio add-on) |
| [cilium.md](services/cilium.md) | `kube-system` | eBPF CNI + Hubble flow observability (overlay or `LAB_CNI=cilium` for sole-CNI) |

## Shared Services (Azure emulators)

| Doc | Namespace | Azure equivalent |
|-----|-----------|-----------------|
| [azurite.md](services/azurite.md) | `azure-storage` | Azure Blob / Queue / Table Storage |
| [azure-sql.md](services/azure-sql.md) | `azure-sql` | Azure SQL / SQL Server |
| [service-bus.md](services/service-bus.md) | `service-bus` | Azure Service Bus |
| [cosmos-db.md](services/cosmos-db.md) | `cosmos-db` | Azure Cosmos DB (NoSQL API) |
| [container-registry.md](services/container-registry.md) | `container-registry` | Azure Container Registry |

## Applications

| Doc | Namespace | Description |
|-----|-----------|-------------|
| [taskflow.md](services/taskflow.md) | `taskapp` | Three-tier task app — Nginx → Node.js → PostgreSQL |
| [blob-explorer.md](services/blob-explorer.md) | `blob-explorer` | ASP.NET Core Blob Storage browser |

## IaC

| Doc | Description |
|-----|-------------|
| [terraform.md](iac/terraform.md) | Terraform lab provisioner — Vault dev server, Vault config (KV/PKI/K8s auth), and Lima VMs |
| [packer.md](iac/packer.md) | Packer VM image builder — pre-bake samba-ad and corp-client base images |
| [ado.md](iac/ado.md) | Azure DevOps submodule — Bicep templates, YAML pipeline definitions, and self-hosted agent setup |

## CLI tool references

Per-tool references for working fast in the exam terminal (CKA / CKAD / CKS). Every tool covered is present in the real exam.

| Doc | Description |
|-----|-------------|
| [cli/](cli/) | **Index** — vim, tmux, jq, grep/sed/awk/less, and bash, each with K8s-flavoured shortcuts and examples |
| [cli/vim.md](cli/vim.md) | Editing YAML fast — modes, navigation, search/replace, paste-safe YAML, repo `\k`/`\d` apply shortcuts |
| [cli/tmux.md](cli/tmux.md) | Splitting the terminal into kubectl / editor / logs panes (vanilla `Ctrl-b` vs repo `Ctrl-a`) |
| [cli/jq.md](cli/jq.md) | Filtering `kubectl -o json` — `.items[]`, `select()`, decoding secrets, node/RBAC inspection |
| [cli/text-tools.md](cli/text-tools.md) | grep / sed / awk / less for log hunting, bulk edits, and column extraction |
| [cli/bash.md](cli/bash.md) | History search, redirection, heredocs, brace expansion, loops, and xargs |

## Guides

| Doc | Description |
|-----|-------------|
| [incidenthub/](guides/incidenthub/) | **Master walkthrough** — 26 stages building a .NET app while learning the cluster, covering CKAD + CKA + CKS topics |
| [monitoring-walkthrough.md](guides/monitoring-walkthrough.md) | Six-stage guide — scrape pipeline, PromQL, dashboards, alerting, custom instrumentation, Azure parity |
| [auth-walkthrough.md](guides/auth-walkthrough.md) | Nine-stage guide to the full SSO authentication chain |
| [vault-walkthrough.md](guides/vault-walkthrough.md) | Eight-stage guide to Vault KV, Kubernetes auth, and Private Link DNS |
| [cert-manager-walkthrough.md](guides/cert-manager-walkthrough.md) | Seven-stage guide to PKI hierarchy, cert issuance, revocation, and auto-renewal |
| [reflector-walkthrough.md](guides/reflector-walkthrough.md) | Four-stage guide — mirror cert-manager TLS secrets across namespaces with rotation |
| [kyverno-walkthrough.md](guides/kyverno-walkthrough.md) | Five-stage guide — audit → enforce → mutate → generate → image verification |
| [falco-walkthrough.md](guides/falco-walkthrough.md) | Four-stage guide — trigger detections, tune false positives, forward events |
| [istio-walkthrough.md](guides/istio-walkthrough.md) | Six-stage guide — sidecar injection, mTLS, traffic shifting, AuthorizationPolicy |
| [cilium-walkthrough.md](guides/cilium-walkthrough.md) | Five-stage guide — Hubble flows, identity-aware policy, L7 enforcement, audit mode |
| [lab-features.md](lab-features.md) | How to enable / disable optional lab components |
| [system-requirements.md](system-requirements.md) | Hardware requirements, memory profiles, and recommended deployment configurations |
