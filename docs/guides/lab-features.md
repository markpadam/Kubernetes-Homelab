# Lab Feature Management

The lab uses a modular component system. Each component can be enabled or disabled independently, at setup time or any time while the cluster is running.

---

## How it works

- **`lab-components.json`** — registry of every available component with its namespace, manifests, dependencies, and port-forwards.
- **`.lab-state.json`** — runtime state file (git-ignored) that records which components are currently enabled. Written by `lab-feature.sh` and read by `setup-lab.sh` / `resume-lab.sh`.
- **`lab-feature.sh`** — the CLI for managing components. Call it from the repo root.

---

## Choosing components at setup

```bash
# Standard defaults (most components — recommended for first run)
./setup-lab.sh --standard

# Everything, including SambaAD, Corp Client, Cosmos DB, Argo Workflows
./setup-lab.sh --all

# Minimal: cluster only, no optional components
./setup-lab.sh --minimal

# Interactive checkbox menu — choose exactly what you want
./setup-lab.sh
```

---

## Managing components at runtime

```bash
# List all components with their enabled/disabled status
./lab-feature.sh list

# Show full status (group, type, port-forwards, dependencies)
./lab-feature.sh status

# Enable a single component
./lab-feature.sh enable cosmos-db

# Enable an entire group
./lab-feature.sh enable storage

# Disable a component (deletes its namespace)
./lab-feature.sh disable cosmos-db

# Disable with dependents (skips dependency warning)
./lab-feature.sh disable samba-ad --force

# Check if a component is enabled (exit 0 = yes, 1 = no)
./lab-feature.sh is-enabled vault
```

---

## Dashboard toggles

The lab dashboard (http://localhost:9997) has a **Lab Management** section at the bottom. Each component has a toggle switch:

- **Turning on** an already-disabled component applies its manifests and starts its port-forwards.
- **Turning off** shows a confirmation modal then deletes the namespace and stops its port-forwards.
- Output streams live into the terminal panel.

---

## Component groups

| Group | Components |
|-------|-----------|
| `infrastructure` | vault, monitoring, argocd, toolbox |
| `identity` | samba-ad, dex, oauth2-proxy, corp-client |
| `storage` | azurite, azure-sql, cosmos-db, service-bus, container-registry |
| `apps` | taskflow, blob-explorer, argo-workflows |

---

## Default components

These are enabled by `--standard` and when no flag is given:

- `vault`, `monitoring`, `argocd`, `toolbox`
- `azurite`, `azure-sql`, `service-bus`, `container-registry`
- `taskflow`, `blob-explorer`

Optional (not on by default):

- `samba-ad`, `dex`, `oauth2-proxy`, `corp-client` — the SSO identity stack (requires Multipass)
- `cosmos-db` — Cosmos DB NoSQL emulator (heavier)
- `argo-workflows` — Argo Workflows engine

---

## Dependencies

Some components require others to be enabled first:

- `dex` → requires `samba-ad`
- `oauth2-proxy` → requires `dex`
- `corp-client` → requires `samba-ad`
- `blob-explorer` → requires `azurite`

`lab-feature.sh enable` auto-enables dependencies. `lab-feature.sh disable` warns if dependents are still enabled (use `--force` to override).

---

## State file

`.lab-state.json` is created in the repo root by `lab-feature.sh init` and updated on every enable/disable. It is git-ignored — each developer has their own feature selection.

Example:
```json
{
  "version": 1,
  "enabled": ["vault", "monitoring", "argocd", "toolbox", "azurite", "azure-sql", "taskflow"]
}
```

---

See also: [auth-walkthrough.md](auth-walkthrough.md) (for the full SSO identity stack)
