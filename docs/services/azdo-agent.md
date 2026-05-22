# Azure DevOps Agent

**Runs in:** `azdo-agent` namespace
**Network:** outbound HTTPS to `dev.azure.com` only — no ingress required
**Azure equivalent:** self-hosted Azure Pipelines agent pool running on AKS or a VM scale set
**Installed by:** `scripts/lab-feature.sh` `_enable_azdo_agent` — applies `flux/apps/base/azdo-agent/`
**Default:** no — opt-in via `./aks-lab feature enable azdo-agent`

## Overview

Runs the `azure-pipelines-agent` container in the cluster so you can execute real Azure DevOps YAML pipelines against this lab — push code, watch the pipeline log stream, build an image, and have it deployed to the cluster without leaving your Mac.

The agent registers with an ADO **agent pool** using a Personal Access Token (PAT). Once registered it polls Azure DevOps for jobs and runs them as subprocesses inside the pod.

## Prerequisites — one-time ADO setup (free)

1. Sign in at [dev.azure.com](https://dev.azure.com) with any Microsoft account.
2. **Organisation Settings → Agent pools → Add pool → Self-hosted** — name it (e.g. `aks-lab`).
3. **User Settings → Personal Access Tokens → New token**
   - Scope: **Agent Pools (Read & Manage)**
   - Copy the token — it is shown only once.

## Enable

```bash
./aks-lab feature enable azdo-agent
```

The script prompts for three values:

| Prompt | Example | Where to find it |
|--------|---------|------------------|
| ADO org URL | `https://dev.azure.com/yourorg` | URL bar after signing in to ADO |
| Agent pool name | `aks-lab` | The pool you created above |
| PAT | `xxxxxxxxxxx…` | The token you just generated |

They are written to the `azdo-agent-secret` Kubernetes Secret and consumed by the Deployment.

## Verify

```bash
# Watch the agent register with ADO
kubectl logs -n azdo-agent deployment/azdo-agent -f
```

In ADO: **Organisation Settings → Agent pools → <pool> → Agents** — the agent should show as **Online** within ~30 seconds.

## Running a pipeline

In your ADO project, edit `azure-pipelines.yml`:

```yaml
pool:
  name: aks-lab           # the pool name you created

stages:
  - stage: BuildAndDeploy
    jobs:
      - job: build
        steps:
          - script: kubectl get nodes
            displayName: Verify cluster access
```

Push the change; the pipeline picks up your agent and runs the job inside the cluster pod.

The agent inherits the pod's service-account permissions, so `kubectl` works against the cluster out of the box.

## Disabling

```bash
./aks-lab feature disable azdo-agent
```

Deletes the deployment, secret, and namespace. The agent is automatically removed from the ADO pool after a few minutes of being offline. The PAT itself is untouched — rotate it in ADO if you no longer want lab access.

## Azure equivalent

A Microsoft-hosted agent (the default `ubuntu-latest` pool) is the closest functional equivalent — but a self-hosted agent on AKS gives you in-cluster network access, custom tooling, and access to private resources (Azurite, in-cluster registry, internal DNS) that a Microsoft-hosted agent cannot reach.
