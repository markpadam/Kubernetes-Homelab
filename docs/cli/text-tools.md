# grep · sed · awk · less

**Exam terminal:** ✅ all available
**Purpose:** Hunt through logs, filter command output, and make bulk edits to manifests
faster than you could by hand in vim.

These four standard Unix tools are always present. You don't need mastery — you need a
few patterns for "find the line that matches", "change X to Y everywhere", "pull out the
3rd column", and "page through a huge log".

## grep — find matching lines

```bash
grep "pattern" file              # lines containing pattern
kubectl logs mypod | grep -i error   # case-insensitive
```

| Flag | Effect |
|------|--------|
| `-i` | case-insensitive |
| `-v` | invert — lines that do **not** match |
| `-r` | recurse into directories |
| `-n` | show line numbers |
| `-c` | count matching lines |
| `-o` | print only the matched text, not the whole line |
| `-A 3` / `-B 3` / `-C 3` | 3 lines After / Before / around (Context) each match |
| `-E` | extended regex (`a\|b`, `+`, `?`) |

Exam-flavoured:

```bash
# Errors in a pod's logs, with 2 lines of surrounding context
kubectl logs payment-api | grep -i -C2 "error\|fail\|exception"

# Which kube-system pods are not Running
kubectl get pods -n kube-system | grep -v Running

# Find a config key across a tree of manifests
grep -rn "imagePullPolicy" ./manifests/
```

## sed — stream edit (substitute, delete)

The one you'll use most is substitution: `s/old/new/`.

```bash
sed 's/old/new/' file        # replace first match per line (to stdout)
sed 's/old/new/g' file       # replace all matches per line
sed -i 's/old/new/g' file    # edit the file IN PLACE
```

| Pattern | Effect |
|---------|--------|
| `sed -n '5,10p' file` | print only lines 5–10 |
| `sed '/^#/d' file` | delete comment lines |
| `sed '/^$/d' file` | delete blank lines |
| `sed -i 's# image:.*# image: nginx:1.25#' deploy.yaml` | swap an image tag |

The delimiter doesn't have to be `/` — use `|` or `#` when the text contains slashes
(paths, image names): `sed 's#/old/path#/new/path#g'`.

> ⚠️ `sed -i` rewrites the file with no undo. On exam manifests, prefer editing in vim
> where you can `u` to undo — or copy the file first (`cp x x.bak`).

## awk — columns and fields

awk splits each line into fields (`$1`, `$2`, …; `$0` is the whole line) on whitespace by
default. Perfect for carving up `kubectl get` output.

```bash
# Print just the pod NAME column (column 1)
kubectl get pods | awk '{print $1}'

# Skip the header row, print name + status (cols 1 and 3)
kubectl get pods | awk 'NR>1 {print $1, $3}'

# Only rows where the status column isn't "Running"
kubectl get pods | awk '$3 != "Running" {print $1, $3}'

# Sum the RESTARTS column (col 4)
kubectl get pods | awk 'NR>1 {sum += $4} END {print sum}'
```

| Piece | Meaning |
|-------|---------|
| `$1`, `$3` | first, third field |
| `NR` | current row number (`NR>1` skips the header) |
| `-F:` | use `:` as the field separator (e.g. parsing `/etc/passwd`) |
| `'/pat/ {...}'` | run the action only on lines matching `pat` |

## less — page through long output

When output (or a log file) is too long to read in one screen, pipe it to `less`:

```bash
kubectl logs busy-pod | less
kubectl describe pod busy-pod | less
```

| Key | Action |
|-----|--------|
| `Space` / `b` | page down / up |
| `g` / `G` | jump to start / end |
| `/text` | search forward |
| `?text` | search backward |
| `n` / `N` | next / previous match |
| `F` | follow mode — live tail, like `tail -f` (`Ctrl-c` to stop) |
| `q` | quit |

`kubectl logs -f` already streams; use `less +F` on a file when you want tail-with-search.

## Putting them together

```bash
# Top 3 pods by restart count, names only
kubectl get pods --no-headers \
  | sort -k4 -nr \
  | awk '{print $1, $4}' \
  | head -3

# Every unique image across the cluster, one per line, paged
kubectl get pods -A -o wide \
  | awk 'NR>1 {print $8}' \
  | sort -u | less
```

## See also

- [jq.md](jq.md) — when the output is JSON, reach for jq instead
- [bash.md](bash.md) — pipes, redirection, and loops that glue these together
- [vim.md](vim.md) — interactive edits where sed would be risky
