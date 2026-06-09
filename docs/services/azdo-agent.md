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

## Credential storage

Credentials are resolved in this order on every enable/redeployment:

1. **`~/.lab-ado`** (plain-text, chmod 600) — written on first interactive run; loaded automatically on subsequent runs without prompting.
2. **macOS Keychain** — if `~/.lab-ado` is absent, the script reads from three Keychain entries before falling back to interactive prompts:

| Keychain service | Contains |
|-----------------|---------|
| `aks-lab-ado-url` | ADO org URL (`https://dev.azure.com/yourorg`) |
| `aks-lab-ado-token` | Personal Access Token |
| `aks-lab-ado-pool` | Agent pool name |

To pre-populate the Keychain (recommended — survives `~/.lab-ado` deletion):

```bash
security add-generic-password -U -a "$USER" -s "aks-lab-ado-url"   -w "https://dev.azure.com/yourorg"
security add-generic-password -U -a "$USER" -s "aks-lab-ado-token" -w "YOUR_ADO_PAT"
security add-generic-password -U -a "$USER" -s "aks-lab-ado-pool"  -w "aks-lab"
```

Credentials stored in the Keychain are encrypted at rest and only accessible to your user account.

## Enable

```bash
./aks-lab feature enable azdo-agent
```

On first run the script prompts for three values (if neither `~/.lab-ado` nor Keychain entries exist):

| Prompt | Example | Where to find it |
|--------|---------|------------------|
| ADO org URL | `https://dev.azure.com/yourorg` | URL bar after signing in to ADO |
| Agent pool name | `aks-lab` | The pool you created above |
| PAT | `xxxxxxxxxxx…` | The token you just generated |

They are written to `~/.lab-ado` and the macOS Keychain, and then stored in the `azdo-agent-secret` Kubernetes Secret.

## Startup retry behaviour

The agent container's `start.sh` runs `config.sh` (which registers with ADO over HTTPS) before starting the agent listener. If the connection to `dev.azure.com` is temporarily unavailable at pod startup — common on this lab due to intermittent routing through the Colima VM — the script retries up to **5 times** with linear backoff (10 s, 20 s, 30 s, 40 s) before exiting. This prevents the crash-restart loop that would otherwise accumulate pod restarts during transient network outages.

## Verify

```bash
# Watch the agent register with ADO
kubectl logs -n azdo-agent deployment/azdo-agent -f
```

Expected output once healthy:

```text
Configuring Azure Pipelines agent...
>> Connect:
Connecting to server ...
>> Register Agent:
Successfully added the agent
2026-06-09 09:22:03Z: Listening for Jobs
```

In ADO: **Organisation Settings → Agent pools → \<pool\> → Agents** — the agent should show as **Online** within ~30 seconds.

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

## Troubleshooting

### Pod keeps restarting

The retry loop handles transient failures. If it exhausts all 5 attempts the container exits and Kubernetes restarts it, which is the correct recovery behaviour. Check the logs for the underlying error:

```bash
kubectl logs -n azdo-agent deployment/azdo-agent --previous
```

Common causes: expired PAT, wrong pool name, or a sustained network outage. Rotate the PAT and update the secret:

```bash
kubectl create secret generic azdo-agent-secret \
  --from-literal=azp-url="$AZP_URL" \
  --from-literal=azp-token="NEW_PAT" \
  --from-literal=azp-pool="$AZP_POOL" \
  --namespace azdo-agent \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/azdo-agent -n azdo-agent
```

### Agent shows Offline in ADO

The agent deregisters itself on SIGTERM (graceful shutdown). If the pod was killed hard or the node crashed, the agent entry may stay as Offline until the new pod registers (usually within 60 s). If it persists, trigger a manual rollout:

```bash
kubectl rollout restart deployment/azdo-agent -n azdo-agent
```

## Disabling

```bash
./aks-lab feature disable azdo-agent
```

Deletes the deployment, secret, and namespace. The agent is automatically removed from the ADO pool after a few minutes of being offline. The PAT and Keychain entries are untouched — rotate the PAT in ADO if you no longer want lab access.

## Azure equivalent

A Microsoft-hosted agent (the default `ubuntu-latest` pool) is the closest functional equivalent — but a self-hosted agent on AKS gives you in-cluster network access, custom tooling, and access to private resources (Azurite, in-cluster registry, internal DNS) that a Microsoft-hosted agent cannot reach.
