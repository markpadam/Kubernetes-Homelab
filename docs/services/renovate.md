# Renovate

**Runs in:** `renovate` namespace (a `CronJob`, not a long-running Deployment)
**Network:** outbound HTTPS to `api.github.com` / `github.com` only — no ingress required
**Azure equivalent:** the hosted Mend Renovate App, or Renovate driven from an Azure Pipeline (GitHub Dependabot is the lighter built-in peer)
**Installed by:** `scripts/lab-feature.sh` `_enable_renovate` — applies `flux/apps/base/renovate/`
**Default:** no — opt-in via `./aks-lab feature enable renovate`

## Overview

Renovate is a self-hosted dependency bot. On a schedule it clones this repository, works out which pinned versions are out of date, and opens (or refreshes) a pull request per update — then exits. It keeps the things the lab pins current: Flux `HelmRelease` chart versions, Dockerfile base images, and GitHub Actions. The locally-built `aks-lab/*` and `azdo-agent:local` images have no upstream registry, so they are explicitly disabled in [`renovate.json`](../../renovate.json).

There is nothing to watch in the cluster between runs — the interesting output is on GitHub: the PRs and the **Dependency Dashboard** issue. For the full hands-on tour see the [Renovate Walkthrough](../guides/renovate-walkthrough.md).

### Configuration split

| File | Scope | Holds |
|------|-------|-------|
| `flux/apps/base/renovate/configmap.yaml` → `config.js` | the **bot** | platform, `autodiscover: false`, `onboarding: false` — bot-only settings |
| [`renovate.json`](../../renovate.json) (repo root) | the **repo** | enabled managers, `packageRules`, grouping, Dependency Dashboard |

The token and repository list are **never committed** — they are injected as `RENOVATE_TOKEN` / `RENOVATE_REPOSITORIES` env vars from the `renovate-env` Secret.

## Prerequisites — a GitHub token

Create a Personal Access Token for the repo you want managed:

- **Classic PAT** — `repo` scope, or
- **Fine-grained PAT** — `Contents` (Read/Write) + `Pull requests` (Read/Write) on that one repository.

## Enable

```bash
./aks-lab feature enable renovate
```

The script prompts for:

| Prompt | Example | Notes |
|--------|---------|-------|
| Repo to manage | `markpadam/Kubernetes-Homelab` | `owner/name`; defaults to this checkout's `origin` |
| GitHub PAT | `ghp_xx…` / `github_pat_xx…` | scopes above |
| Dry run first? | `y` / `N` | `y` opens no PRs — just logs what it would do |

Values are saved to `~/.lab-renovate` (chmod 600), written to the `renovate-env` Secret, and the manifests are applied. The script then triggers an immediate bootstrap run so you get feedback now rather than at 02:00, and waits for it — reporting a token/repo failure distinctly from a merely slow run.

## Verify

```bash
# The schedule and the bootstrap run
kubectl -n renovate get cronjob renovate
kubectl -n renovate get jobs,pods

# Trigger an on-demand run any time (don't wait for 02:00)
kubectl -n renovate create job --from=cronjob/renovate renovate-now-$(date +%s)
kubectl -n renovate logs -l app=renovate -f
```

On GitHub:

```bash
gh pr list   --repo <owner/repo> --label renovate    # the update PRs
gh issue list --repo <owner/repo> --label renovate   # the Dependency Dashboard
```

## Operating

- **Schedule** lives in `flux/apps/base/renovate/cronjob.yaml` (`schedule: "0 2 * * *"`). Change it and commit — Flux reconciles it.
- **Dry-run toggle** — edit `RENOVATE_DRY_RUN` in `~/.lab-renovate` (set to `full` for dry run, empty for live) and re-run `./aks-lab feature enable renovate`, or patch the `renovate-env` Secret directly.
- **Bot version** — the CronJob runs `ghcr.io/renovatebot/renovate:latest`. Pin a major tag to let Renovate open PRs that bump its own pin (the `renovate self-update` rule already matches it).
- **Dependency Dashboard** — the single GitHub issue Renovate maintains; tick a checkbox there to force a rate-limited PR.

## Disabling

```bash
./aks-lab feature disable renovate
```

Deletes the CronJob, any Jobs, the `renovate-env` Secret, and the namespace. **Open PRs and the Dependency Dashboard issue on GitHub are left untouched** — close them on GitHub if you don't want them. The PAT is not modified; revoke it in GitHub if you no longer want lab access. Run `rm -f ~/.lab-renovate` to forget the stored token.

## Azure equivalent

Renovate is the engine behind the **hosted Mend Renovate App** on GitHub; running it self-hosted here is the pattern you'd use when the token and runner must stay inside your own infrastructure. On Azure DevOps the same engine is typically run from a scheduled Azure Pipeline (the [azdo-agent](azdo-agent.md) is exactly the kind of self-hosted runner that would execute it). **GitHub Dependabot** is the lighter, built-in alternative — fewer managers and no Flux/kustomize awareness or cross-dependency grouping.
