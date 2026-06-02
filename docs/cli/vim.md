# vim

**Exam terminal:** ✅ available (it's the default editor)
**Purpose:** Edit Kubernetes YAML manifests fast and without indentation mistakes.

Vim is the editor you will live in during CKA / CKAD / CKS tasks. You do not need to be
a power user — you need a small, reliable set of moves you can do without thinking. This
doc covers exactly that, plus the YAML-safety habits that stop tasks failing on a stray
tab or mangled indent.

> **Repo config:** [exam-sim/.vimrc](../../exam-sim/.vimrc) pre-sets 2-space expand-tab
> indentation, line numbers, search highlighting, and a few leader shortcuts. Install it
> with `exam-sim/setup.sh`. Mappings marked **(repo)** below only exist with that vimrc;
> everything else is vanilla vim and works in the real exam.

## The three modes

```text
Normal  — navigate and run commands (where you start, and where you return)
Insert  — type text. Enter with i/a/o, leave with Esc
Command — :w :q :%s/.../ etc. Enter with : from Normal mode
```

The golden rule: **when in doubt, press `Esc`** to get back to Normal mode.

## Entering insert mode

| Key | Action |
|-----|--------|
| `i` | insert before cursor |
| `a` | append after cursor |
| `o` | open new line below and insert |
| `O` | open new line above and insert |
| `I` | insert at start of line |
| `A` | append at end of line |

## Saving and quitting

| Command | Action |
|---------|--------|
| `:w` | save (write) |
| `:wq` or `:x` | save and quit |
| `ZZ` | save and quit (Normal mode, no colon) |
| `:q` | quit (fails if unsaved changes) |
| `:q!` | quit, discard changes |
| `:wq!` | force save and quit |

## Moving around

| Key | Action |
|-----|--------|
| `h j k l` | left, down, up, right |
| `w` / `b` | next / previous word |
| `0` / `$` | start / end of line |
| `gg` / `G` | top / bottom of file |
| `:42` | jump to line 42 |
| `{` / `}` | previous / next blank line (jump between YAML blocks) |
| `Ctrl-d` / `Ctrl-u` | half page down / up |

With `relativenumber` on (set in the repo vimrc), counts are easy: if a line shows `3`,
`3dd` deletes from the cursor down through it, `3j` jumps to it.

## Editing

| Key | Action |
|-----|--------|
| `x` | delete character under cursor |
| `dd` | delete (cut) current line |
| `3dd` | delete 3 lines |
| `yy` | yank (copy) current line |
| `3yy` | yank 3 lines |
| `p` / `P` | paste below / above |
| `cc` | change whole line (clears it, enters insert) |
| `dw` / `cw` | delete / change to end of word |
| `r<char>` | replace single character |
| `u` | undo |
| `Ctrl-r` | redo |
| `.` | repeat last change (huge time-saver) |

## Visual mode (selecting blocks)

| Key | Action |
|-----|--------|
| `v` | character-wise visual select |
| `V` | line-wise visual select |
| `Ctrl-v` | block (column) visual select |
| `y` / `d` | yank / delete the selection |
| `>` / `<` | indent / un-indent selection |

`V` then `j`/`k` to grab a YAML block, then `d` to cut or `>` to indent it one level —
the fastest way to move a `containers:` or `env:` section around.

## Search and replace

| Command | Action |
|---------|--------|
| `/text` | search forward for "text" |
| `?text` | search backward |
| `n` / `N` | next / previous match |
| `:%s/old/new/g` | replace all "old" with "new" in file |
| `:%s/old/new/gc` | same, but confirm each |
| `Esc Esc` | clear search highlight **(repo)** |

Example — bump an image tag across a manifest:

```vim
:%s/nginx:1.21/nginx:1.25/g
```

## YAML survival kit

YAML breaks on inconsistent indentation and on tab characters. The repo vimrc already
forces 2-space soft tabs, but know these regardless:

| Action | How |
|--------|-----|
| Paste without auto-indent mangling | `:set paste`, paste, `:set nopaste` |
| Paste toggle key | `F2` **(repo)** — flips paste mode on/off |
| Force 2-space YAML indent on a buffer | `\y` **(repo)** |
| See whitespace / tabs | `:set list` |
| Indent a visual block | select with `V`, press `>` |

When you copy YAML from the Kubernetes docs into vim, **always** use paste mode (`F2` or
`:set paste`) first — otherwise vim's auto-indent stacks indentation on every line and
the manifest is silently corrupted.

## Apply YAML without leaving vim (repo)

The repo vimrc wires kubectl to leader shortcuts (`\` is the leader key):

| Mapping | Runs |
|---------|------|
| `\d` | `kubectl apply -f % --dry-run=client` — validate the current file |
| `\k` | `kubectl apply -f %` — apply the current file |
| `\w` | `:w` save |
| `\q` | `:q` quit |
| `\x` | `:x` save and quit |

Typical loop: edit manifest → `\d` to catch errors → `\k` to apply. In the **real exam**
these mappings don't exist; use `:w` then `:!kubectl apply -f %` instead (the `:!` prefix
runs any shell command from inside vim).

## Quick exam workflow

```bash
# Generate a manifest skeleton, then refine it in vim
k run nginx --image=nginx $do > pod.yaml   # $do = --dry-run=client -o yaml
vim pod.yaml
#   gg          jump to top
#   /image      find the image line
#   o           open a line to add resources/env/probes
#   Esc :wq     save and quit
k apply -f pod.yaml
```

## See also

- [tmux.md](tmux.md) — run vim in one pane, kubectl in another
- [text-tools.md](text-tools.md) — grep/sed/awk for bulk edits vim isn't ideal for
- [exam-sim/.vimrc](../../exam-sim/.vimrc) — the exact config these shortcuts come from
- [docs/guides/exam-sim-walkthrough.md](../guides/exam-sim-walkthrough.md) — full exam practice guide
