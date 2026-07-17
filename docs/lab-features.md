# Lab Feature Management

The lab uses a modular component system. Each component can be enabled or disabled independently, at setup time or any time while the cluster is running.

---

## How it works

- **`lab-components.json`** — registry of every available component with its namespace, manifests, dependencies, and port-forwards.
- **`.lab-state.json`** — runtime state file (git-ignored) that records which components are currently enabled. Written by `./aks-lab feature` (via `scripts/lab-feature.sh`) and read by `./aks-lab setup` / `./aks-lab resume`.
- **`./aks-lab feature ...`** — the user-facing interface for enabling, disabling, and inspecting components. It dispatches to `scripts/lab-feature.sh` under the hood.

---

## Choosing components at setup

```bash
# Standard defaults (most components — recommended for first run)
./aks-lab setup --standard

# Everything, including SambaAD, Corp Client, Cosmos DB, Argo Workflows
./aks-lab setup --all

# Minimal: cluster only, no optional components
./aks-lab setup --minimal

# Interactive checkbox menu — choose exactly what you want
./aks-lab setup
```

---

## Managing components at runtime

```bash
# List all components with their enabled/disabled status
./aks-lab feature list

# Show full status (group, type, port-forwards, dependencies)
./aks-lab feature status

# Enable a single component
./aks-lab feature enable cosmos-db

# Enable an entire group
./aks-lab feature enable storage

# Disable a component (deletes its namespace)
./aks-lab feature disable cosmos-db

# Disable with dependents (skips dependency warning)
./aks-lab feature disable samba-ad --force

# Check if a component is enabled (exit 0 = yes, 1 = no)
./aks-lab feature is-enabled vault
```

---

## Dashboard toggles

The lab dashboard (<http://localhost:9997>) has a **Lab Management** section at the bottom. Each component has a toggle switch:

- **Turning on** an already-disabled component applies its manifests and starts its port-forwards.
- **Turning off** shows a confirmation modal then deletes the namespace and stops its port-forwards.
- Output streams live into the terminal panel.

---

## Component groups

| Group | Components |
|-------|-----------|
| `infrastructure` | cert-manager, vault, monitoring, argocd, toolbox |
| `identity` | samba-ad, dex, oauth2-proxy, corp-client |
| `storage` | azurite, azure-sql, cosmos-db, service-bus, container-registry |
| `apps` | taskflow, blob-explorer, argo-workflows, azdo-agent, renovate |

---

## Default components

These are enabled by `--standard` and when no flag is given:

- `cert-manager`, `vault`, `monitoring`, `argocd`, `toolbox`
- `azurite`, `azure-sql`, `service-bus`, `container-registry`
- `taskflow`, `blob-explorer`

Optional (not on by default):

- `samba-ad`, `dex`, `oauth2-proxy`, `corp-client` — the SSO identity stack (requires Lima)
- `cosmos-db` — Cosmos DB NoSQL emulator (heavier)
- `argo-workflows` — Argo Workflows engine
- `keda`, `keda-servicebus` — event-driven autoscaling demo
- `azdo-agent` — self-hosted Azure Pipelines agent (needs `~/.lab-ado`)
- `renovate` — self-hosted dependency-update bot (needs a GitHub token; see the [Renovate Walkthrough](guides/renovate-walkthrough.md))

---

## Dependencies

Some components require others to be enabled first:

- `cert-manager` → requires `vault`
- `dex` → requires `samba-ad`
- `oauth2-proxy` → requires `dex`
- `corp-client` → requires `samba-ad`
- `blob-explorer` → requires `azurite`
- `service-bus` → requires `azure-sql`
- `keda-servicebus` → requires `keda` and `service-bus`

`./aks-lab feature enable` auto-enables dependencies. `./aks-lab feature disable` warns if dependents are still enabled (use `--force` to override).

---

## State file

`.lab-state.json` is created in the repo root by `./aks-lab feature init` and updated on every enable/disable. It is git-ignored — each developer has their own feature selection.

Example:

```json
{
  "version": 1,
  "enabled": ["vault", "monitoring", "argocd", "toolbox", "azurite", "azure-sql", "taskflow"]
}
```

---

See also: [auth-walkthrough.md](guides/auth-walkthrough.md) (for the full SSO identity stack)
