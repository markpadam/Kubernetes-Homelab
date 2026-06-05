# Renovate Walkthrough

A six-stage guide to running **Renovate** self-hosted in the lab as a dependency bot. Renovate scans *this* GitHub repository on a schedule and opens pull requests to bump the versions the lab actually pins — Flux `HelmRelease` charts, Dockerfile base images, and GitHub Actions — while leaving the locally-built `aks-lab/*` images alone. It's the same job GitHub's Dependabot or the hosted Mend Renovate App does, but running as a `CronJob` inside your own cluster with your own token.

Unlike most lab components there's nothing long-running to look at: Renovate is a **batch job**. It starts, clones the repo, works out what's out of date, opens/refreshes PRs, then exits. The interesting output lives on GitHub (the PRs and the *Dependency Dashboard* issue), not in a pod.

Prerequisites:

```bash
# A GitHub Personal Access Token for the repo you want managed:
#   - classic PAT:        repo scope
#   - fine-grained PAT:   Contents (RW) + Pull requests (RW) on that one repo
./aks-lab feature enable renovate
```

The enable flow prompts for the repo (`owner/name`, defaulting to this checkout's `origin`), the token, and whether to do a dry run first. It stores them in `~/.lab-renovate` (chmod 600), creates the `renovate-env` Secret, applies the manifests, and kicks an immediate run so you get feedback now instead of at 02:00.

---

## Stage 1 — The problem Renovate solves

The lab pins versions in a lot of places. Find them:

```bash
# Flux HelmRelease chart versions
grep -rn 'version:' flux --include=helmrelease.yaml | head

# Dockerfile base images
grep -rhn '^FROM ' src/*/Dockerfile flux/apps/base/azdo-agent/Dockerfile

# GitHub Actions pinned by tag
grep -rn 'uses:' .github/workflows/
```

Every one of those is a thing that goes stale silently. Manually checking upstream for each chart, base image, and action — then testing the bump — is exactly the toil Renovate removes. It opens a separate, reviewable PR per dependency (or grouped, per this lab's config), with the changelog inline, so upgrading becomes "read the diff, watch CI, merge."

**What you learn:** dependency drift is invisible until something breaks or a CVE lands. A bot that surfaces every available bump as a PR turns that invisible backlog into a visible, mergeable queue.

---

## Stage 2 — How the lab wires Renovate

There are **two** config files, and the split matters:

| File | Scope | Lives in | Holds |
|------|-------|----------|-------|
| `flux/apps/base/renovate/configmap.yaml` → `config.js` | the *bot* | the cluster | platform, `autodiscover: false`, `onboarding: false` — settings that only make sense to the running bot |
| `renovate.json` | the *repo* | repo root | which managers run, `packageRules`, grouping, the Dependency Dashboard — the stuff you normally tune |

The bot reads its global `config.js`, decides it's acting on GitHub against `RENOVATE_REPOSITORIES`, clones that repo, then reads the repo's `renovate.json` for everything else. The token and repo list never touch git — they arrive as env vars from the `renovate-env` Secret:

```bash
kubectl -n renovate get cronjob renovate
kubectl -n renovate get secret renovate-env -o jsonpath='{.data}' | jq 'keys'
#   ["GITHUB_COM_TOKEN","RENOVATE_DRY_RUN","RENOVATE_REPOSITORIES","RENOVATE_TOKEN"]

kubectl -n renovate get configmap renovate-config -o jsonpath='{.data.config\.js}'
```

**What you learn:** self-hosted Renovate has a hard boundary between *bot config* (credentials, which repos, platform) and *repo config* (what to update). Putting `platform` in `renovate.json`, or a token in `config.js`, are the two classic mistakes.

---

## Stage 3 — Trigger a run and read the log

The `CronJob` fires at 02:00, but you never have to wait — create a Job from it on demand:

```bash
kubectl -n renovate create job --from=cronjob/renovate renovate-now-$(date +%s)

# Follow it (the pod is named after the job):
kubectl -n renovate get pods -w
kubectl -n renovate logs -l app=renovate -f
```

In the log, look for these phases:

- `Repository started` / `Found X dependencies` — discovery via the enabled managers
- `Dependency extraction complete` — the per-manager breakdown (flux, dockerfile, github-actions)
- `DRY-RUN: Would create PR` (dry-run mode) **or** `PR created` / `PR updated` (live mode)
- `Dependency Dashboard` — the summary issue it maintains

```bash
# Did it open anything? (live mode)
gh pr list --repo <owner/repo> --label renovate
```

**What you learn:** a Renovate run is idempotent and stateless — it reconciles GitHub to "one PR per pending update." Re-running never duplicates PRs; it refreshes the existing ones.

---

## Stage 4 — The Dependency Dashboard

With `:dependencyDashboard` enabled (it is, via `renovate.json`), Renovate maintains a single GitHub **issue** titled *Renovate Dependency Dashboard*. It's the control panel:

```bash
gh issue list --repo <owner/repo> --label renovate
gh issue view <n> --repo <owner/repo>
```

From that issue you can tick a checkbox to force-create a PR that's being rate-limited, see everything pending at a glance, and find errored dependencies. It's the first place to look when a bump you expected didn't show up.

**What you learn:** the dashboard is how you operate Renovate without reading logs — pending, rate-limited, and errored updates are all one issue away, and check-boxes drive the bot.

---

## Stage 5 — Managers, grouping, and the local-image trap

Open [`renovate.json`](../../renovate.json) and note three deliberate choices:

1. **`enabledManagers`** is an allow-list (`flux`, `helm-values`, `dockerfile`, `kubernetes`, `github-actions`). Renovate has dozens of managers; restricting to the ones this repo uses keeps runs fast and noise-free.
2. **Grouping** — non-major Flux chart bumps land in one PR, base-image patches in another. Majors stay separate so a breaking change is never hidden inside a "patch" PR.
3. **The local-image trap** — the kustomize manager would otherwise try to "update" `image: aks-lab/backend:latest` and `image: azdo-agent:local`, which have no upstream registry. A `packageRule` with `"enabled": false` for `^aks-lab/` and `azdo-agent` switches them off:

```jsonc
{
  "matchManagers": ["kubernetes"],
  "matchPackageNames": ["/^aks-lab\\//", "/^azdo-agent$/"],
  "enabled": false
}
```

Verify Renovate is *not* proposing changes to those by reading the "Dependency extraction" section of the log — they should be absent.

**What you learn:** Renovate is only as good as its scoping. Allow-listing managers and disabling un-trackable (locally-built) images is the difference between a useful queue and a wall of broken PRs.

---

## Stage 6 — Let Renovate update itself, then schedule it

The `CronJob` runs `ghcr.io/renovatebot/renovate:latest` so first-run always pulls. For a self-updating demo, pin it instead and let Renovate bump the pin:

```yaml
# flux/apps/base/renovate/cronjob.yaml
image: ghcr.io/renovatebot/renovate:41
```

The `renovate self-update` `packageRule` already matches `ghcr.io/renovatebot/renovate`, so the next run opens a PR when a newer tag exists — Renovate upgrading Renovate, delivered by Flux.

Tune the cadence in the same file (`schedule: "0 2 * * *"`), then commit so Flux reconciles it:

```bash
kubectl -n renovate get cronjob renovate -o jsonpath='{.spec.schedule}'; echo
```

**What you learn:** because the bot is a Flux-managed `CronJob`, its schedule and even its own version are GitOps — changed by committing YAML, not by clicking in a SaaS dashboard.

---

## Cleanup

```bash
./aks-lab feature disable renovate
# Removes the CronJob, the renovate-env Secret, and the namespace.
# Open PRs and the Dependency Dashboard issue on GitHub are left untouched —
# close them on GitHub if you don't want them.
rm -f ~/.lab-renovate   # forget the stored token/repo
```

## Azure equivalent

Renovate is the bot behind the **hosted Mend Renovate App** on GitHub; running it self-hosted here is what you'd do when policy requires the token and the runner to stay inside your own infrastructure.

The Azure-native equivalents:

- **GitHub Dependabot** — the built-in option for GitHub repos (`.github/dependabot.yml`). Simpler, but fewer managers and no `flux`/kustomize awareness or cross-dependency grouping.
- **Azure DevOps + Mend Renovate** — the same Renovate engine targeting Azure Repos, typically run from an Azure Pipeline on a schedule (the [azdo-agent](../../flux/apps/base/azdo-agent) in this lab is exactly the kind of self-hosted runner that would execute it).
- **Microsoft Defender for DevOps / GitHub Advanced Security** — sit alongside, flagging *vulnerable* dependencies; Renovate is what actually opens the PR that fixes them.

In production AKS-with-Flux estates, self-hosted Renovate is the standard way to keep `HelmRelease` versions, base images, and pipeline actions current without a human watching upstream release feeds.
