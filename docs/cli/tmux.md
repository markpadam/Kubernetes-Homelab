# tmux

**Exam terminal:** ✅ available
**Purpose:** Run several shells side by side in one terminal — kubectl in one pane, a
manifest in vim in another, logs streaming in a third.

The exam gives you a single terminal. tmux lets you split it so you don't lose your place
switching between editing YAML, running `kubectl`, and watching logs.

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
