# tmux

**Exam terminal:** ✅ available
**Purpose:** Run several shells side by side in one terminal — kubectl in one pane, a
manifest in vim in another, logs streaming in a third.

The exam gives you a single terminal. tmux lets you split it so you don't lose your place
switching between editing YAML, running `kubectl`, and watching logs.

## Lab cockpit — `./aks-lab tmux`

Beyond exam practice, this repo ships a ready-made tmux "cockpit" for **driving the
lab day-to-day from a client machine** (e.g. your MacBook). Launch it with:

```bash
./aks-lab tmux          # or: scripts/k8s-tmux.sh   (kill it with: scripts/k8s-tmux.sh kill)
```

It builds (or re-attaches to) a session named **`k8s`** with six windows:

| # | Window | What's in it |
|---|--------|--------------|
| 0 | `control` | interactive action **menu** (wake · resume · pause · doze · verify · feature status · dashboard) — pick a number/letter, press Enter · live **ASLEEP/UP** lab status · a host ops shell |
| 1 | `k9s` | `k9s` running on the host (falls back to a live `kubectl get pods -A -w` if k9s isn't installed there) |
| 2 | `workloads` | `pods -A` · `nodes -o wide`+`top nodes`+`hpa` · `events`, auto-refreshing |
| 3 | `gitops` | `flux get sources/kustomizations` · `flux logs -A --follow` · a reconcile shell |
| 4 | `logs` | host log tails: `/tmp/aks-lab-doze.log`, `/var/log/minikube-tunnel.log`, `/tmp/vault-dev.log` + a `kubectl logs` shell |
| 5 | `services` | web-UI + credential reference (`:9444` ingress, Vault, emulators) and port-forward helpers |

**SSH-native model.** Every cluster/log pane SSHes into the Mac Pro
(`markpadam@192.168.5.89`) and runs the real `kubectl`/`flux`/`k9s`/`tail` there
against the native `aks-lab` context — no dependency on `./aks-lab publish`. All
panes share one multiplexed SSH connection (ControlMaster). Because the lab
[auto-dozes](../guides/doze-power-saving.md), the panes **self-heal**: while the
host is asleep they show a "wake me" banner and wait, then connect on their own
once you run `./aks-lab wake --wait` and resume. The session is built entirely
with the `tmux` CLI, so it never touches your `~/.tmux.conf` — your own prefix
and keybindings still apply inside it.

**Look & feel.** The cockpit themes itself with a dark teal/slate scheme —
coloured window tabs, a status bar with a live **`● UP` / `● ASLEEP`** lab badge
(fed by the status pane), titled/coloured pane borders, and state-coloured
workload panes (Running green · Pending yellow · Crash/Error red). Powerline
separators use the profile's MesloLGS NF font. **Mouse is on** so you can click
panes and scroll logs. All of this is applied _session-scoped_ (no `-g` writes),
so it stays entirely inside the `k8s` session — nothing leaks into your
`~/.tmux.conf`, other sessions, or the [exam-sim](../../exam-sim/.tmux.conf)
practice config. This is the oh-my-tmux look without adopting a global config or
a plugin manager. Attaching from a terminal without a Nerd Font? Launch with
`LAB_TMUX_NF=0 ./aks-lab tmux` to drop the powerline glyphs.

**Auto-access on open.** When the cockpit opens and the host is up, it makes the
lab reachable from this client automatically (in the background — it never blocks
the attach):

- **Dashboard tunnel** — always. The dashboard (`localhost:9997`) is loopback-only
  on the host; the cockpit brings up / reuses the passwordless self-healing SSH
  tunnel (the same one `./aks-lab dashboard` installs), so the browser UI just
  works. No sudo involved.
- **LAN publish** (`*.aks-lab.local` + republished ports) — best effort. This needs
  **sudo on the host**, so the cockpit only runs it silently when host sudo is
  already passwordless _and_ it isn't published yet (the publish LaunchDaemon
  persists across reboots, so this is normally a one-time thing). Otherwise the
  **status pane** shows `LAN: — not published` and you enable it with **`p`** in the
  control menu, which runs `./aks-lab publish` over an interactive SSH so sudo can
  prompt once in that pane. Set `LAB_TMUX_AUTOPUBLISH=0` to skip the whole step.
  For a truly unattended publish, give the host passwordless sudo for it.

Overrides via env: `LAB_SSH_HOST` (e.g. a Tailscale name), `LAB_SSH_USER`,
`LAB_TMUX_SESSION`, `LAB_REPO_REMOTE`, `LAB_TMUX_NF` (`0` disables Nerd-Font
glyphs), `LAB_TMUX_AUTOPUBLISH` (`0` disables auto dashboard-tunnel / LAN publish).

> ⚠️ **Prefix differs between the exam and this repo — read this first.**
>
> Every tmux command starts with a **prefix** key, then the command key.
>
> - **Real exam (vanilla tmux):** prefix is **`Ctrl-b`**. This is what you must train for.
> - **This repo** ([exam-sim/.tmux.conf](../../exam-sim/.tmux.conf)): prefix is remapped
>   to **`Ctrl-a`** (and adds `|` / `-` splits, `Alt+arrow` nav). Convenient locally,
>   but **not** what you'll have on exam day.
>
> Below, **`<prefix>`** means "press your prefix, release, then the next key". Where the
> repo binding differs from vanilla, both are shown. **Practice with `Ctrl-b`** so muscle
> memory matches the exam.

## Starting and leaving

```bash
tmux                    # start a new session
tmux new -s exam        # start a named session "exam"
tmux ls                 # list running sessions
tmux attach -t exam     # re-attach to "exam"
```

| Keys | Action |
|------|--------|
| `<prefix> d` | detach (session keeps running in the background) |
| `exit` or `Ctrl-d` | close the current pane/shell |

Detaching matters: if your session drops, the work survives. Re-attach with
`tmux attach`.

## Panes (splitting one window)

| Action | Vanilla (exam) | Repo binding |
|--------|----------------|--------------|
| Split vertically (side by side) | `<prefix> %` | `<prefix> \|` |
| Split horizontally (stacked) | `<prefix> "` | `<prefix> -` |
| Move between panes | `<prefix> arrow` | `Alt+arrow` (no prefix) |
| Cycle to next pane | `<prefix> o` | `<prefix> o` |
| Zoom pane to fullscreen (toggle) | `<prefix> z` | `<prefix> z` |
| Close current pane | `<prefix> x` then `y` | same |
| Resize pane | `<prefix> Ctrl-arrow` | `<prefix> arrow` (repeatable) |

`<prefix> z` (zoom) is the most useful: blow one pane up to full screen to read long
output or edit, then `<prefix> z` again to return to the split layout.

## Windows (like browser tabs)

| Keys | Action |
|------|--------|
| `<prefix> c` | create a new window |
| `<prefix> n` / `<prefix> p` | next / previous window |
| `<prefix> 0`–`9` | jump to window by number |
| `<prefix> ,` | rename current window |
| `<prefix> w` | list/select windows |
| `<prefix> &` | kill current window |

## Scrolling and copy mode

In tmux you can't just scroll up with the mouse (and the exam terminal has the mouse
**off**). Use copy mode:

| Keys | Action |
|------|--------|
| `<prefix> [` | enter copy/scroll mode |
| `arrow` / `PgUp` / `PgDn` | move around |
| `/text` | search within the scrollback |
| `q` or `Esc` | leave copy mode |

With vi copy keys (set in the repo config, and common in the exam):

| Keys | Action |
|------|--------|
| `v` | start selection |
| `y` | yank (copy) selection and exit |
| `<prefix> ]` | paste what you copied |

## Recommended exam layout

```text
┌────────────────────────┬───────────────────────┐
│ Left pane              │ Right pane            │
│ kubectl commands       │ vim manifest.yaml     │
│ k get / describe / logs│  or a scratch notepad │
└────────────────────────┴───────────────────────┘
```

Build it:

```bash
tmux new -s exam        # start
# <prefix> %            vanilla split (or <prefix> | with repo config)
# <prefix> arrow        hop to the new pane
vim task.yaml           # edit on the right, run kubectl on the left
# <prefix> z            zoom whichever pane you're focused on
```

Keep a scratch pane open with `vim ~/notes.txt` for stashing YAML snippets and the answer
fragments you'll reuse across questions.

## Config reload (repo)

If you edit `~/.tmux.conf`, reload it without restarting:

| Keys | Action |
|------|--------|
| `<prefix> r` | reload config **(repo)** — shows "Config reloaded" |
| (vanilla) | `<prefix> :` then `source-file ~/.tmux.conf` |

## See also

- [vim.md](vim.md) — the editor you'll run in one of these panes
- [bash.md](bash.md) — shell shortcuts for the kubectl pane
- [exam-sim/.tmux.conf](../../exam-sim/.tmux.conf) — the repo config (Ctrl-a prefix, custom binds)
- [docs/guides/exam-sim-walkthrough.md](../guides/exam-sim-walkthrough.md) — full exam practice guide
