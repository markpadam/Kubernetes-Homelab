# CLI Tool References

Focused, scannable references for the command-line tools you use to manage Kubernetes —
written for **CKA / CKAD / CKS exam prep**. Each doc covers the essentials, the
shortcuts, and Kubernetes-flavoured examples, with the goal of building speed under exam
conditions.

**Every tool documented here is present in the real Linux Foundation exam terminal.**
Productivity tools that are *not* in the exam (fzf, ripgrep, bat, …) are deliberately
left out so you only build muscle memory you can actually use on exam day.

| Doc | Tool | What it's for |
|-----|------|---------------|
| [vim.md](vim.md) | vim | Editing YAML manifests fast and without indentation mistakes |
| [tmux.md](tmux.md) | tmux | Splitting one terminal into kubectl / editor / logs panes |
| [jq.md](jq.md) | jq | Filtering and reshaping `kubectl -o json` output |
| [text-tools.md](text-tools.md) | grep · sed · awk · less | Log hunting, bulk edits, column extraction, paging |
| [bash.md](bash.md) | bash | History search, redirection, heredocs, loops, xargs |

## A note on the repo's exam-sim config

The lab ships exam-tuned dotfiles in [exam-sim/](../../exam-sim/) (install with
`exam-sim/setup.sh`):

- [.vimrc](../../exam-sim/.vimrc) — 2-space YAML indent, line numbers, and `\k` / `\d`
  leader shortcuts to apply / dry-run the current file.
- [.tmux.conf](../../exam-sim/.tmux.conf) — remaps the prefix to `Ctrl-a` and adds
  `|`/`-` splits and `Alt+arrow` pane navigation.
- [.exam-aliases](../../exam-sim/.exam-aliases) — `k` for kubectl plus `$do`
  (`--dry-run=client -o yaml`) and `$now` (force-delete) power variables.

Shortcuts that only exist with these dotfiles are labelled **(repo)** in the docs. The
**real exam uses vanilla defaults** — most importantly, tmux uses `Ctrl-b`, not `Ctrl-a`
— so each doc shows the vanilla form too. Practise with the vanilla keys so nothing trips
you up on exam day.

## See also

- [docs/guides/exam-sim-walkthrough.md](../guides/exam-sim-walkthrough.md) — full exam
  practice guide (shell drills, tmux layout, dashboard exam mode, killer.sh tips)
- [docs/services/exam-sim.md](../services/exam-sim.md) — the exam-sim pod reference
