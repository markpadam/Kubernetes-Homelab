# bash

**Exam terminal:** ✅ available (the exam shell is bash)
**Purpose:** The shell glue — recall and edit commands fast, redirect output, generate
manifests with heredocs, and loop over resources. These are the time multipliers that
turn a 4-minute task into a 1-minute one.

> The exam shell is **bash**. Your local machine may use zsh; most of this is identical,
> but a few keybindings (history search) behave the same in both.

## Command-line editing (readline)

Move and edit without arrow-key hammering. These work mid-command:

| Keys | Action |
|------|--------|
| `Ctrl-a` | jump to start of line |
| `Ctrl-e` | jump to end of line |
| `Ctrl-w` | delete the word before the cursor |
| `Ctrl-u` | delete from cursor to start of line |
| `Ctrl-k` | delete from cursor to end of line |
| `Ctrl-l` | clear the screen (keeps the typed line) |
| `Alt-b` / `Alt-f` | move back / forward one word |

## History

| Keys / command | Action |
|----------------|--------|
| `Ctrl-r` | **reverse search** — type a fragment, it finds the last matching command |
| `Ctrl-r` again | step further back through matches |
| `Enter` | run the found command; `Esc`/arrow to edit it first |
| `↑` / `↓` | previous / next command |
| `!!` | the entire previous command |
| `sudo !!` | re-run the last command with sudo |
| `!$` | last argument of the previous command |

`Ctrl-r` is the single biggest exam speed-up: type `drain`, get back your full
`kubectl drain ... --ignore-daemonsets --delete-emptydir-data` line without retyping it.

`!$` chains nicely:

```bash
vim /etc/kubernetes/manifests/kube-apiserver.yaml
ls -l !$        # !$ expands to the file you just edited
```

## Redirection and pipes

| Syntax | Effect |
|--------|--------|
| `cmd > file` | write stdout to file (overwrite) |
| `cmd >> file` | append stdout to file |
| `cmd 2> file` | write stderr to file |
| `cmd > file 2>&1` | stdout **and** stderr to file |
| `cmd 2>/dev/null` | discard errors |
| `cmd1 \| cmd2` | pipe cmd1's output into cmd2 |
| `cmd \| tee file` | show output **and** save it to file |

Exam staple — generate a manifest to a file, then edit it:

```bash
k run nginx --image=nginx $do > pod.yaml    # $do = --dry-run=client -o yaml
vim pod.yaml
k apply -f pod.yaml
```

## Heredocs — create manifests inline

When you don't want to open an editor, pipe a heredoc straight to `kubectl apply`:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: secure
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
```

`-f -` tells kubectl to read the manifest from stdin. Everything between `<<EOF` and the
closing `EOF` is the document.

## Brace expansion

Generate sequences and combinations without typing each one:

```bash
mkdir -p /tmp/lab/{logs,manifests,backup}     # three dirs at once
touch pod-{1..5}.yaml                          # pod-1.yaml ... pod-5.yaml
cp deploy.yaml{,.bak}                          # quick backup -> deploy.yaml.bak
```

## Loops over resources

A `for` loop applied to `kubectl` output handles "do X to every Y" tasks:

```bash
# Restart every deployment in a namespace
for d in $(kubectl get deploy -o name); do
  kubectl rollout restart "$d"
done

# Label all nodes
for n in $(kubectl get nodes -o name); do
  kubectl label "$n" tier=lab --overwrite
done
```

## xargs — feed output as arguments

Some commands take arguments, not stdin. `xargs` bridges a pipe into arguments:

```bash
# Delete every Evicted pod
kubectl get pods | grep Evicted | awk '{print $1}' \
  | xargs kubectl delete pod

# Same, namespaced and safer with -n1 (one at a time)
kubectl get pods -A | awk '/Evicted/ {print $1, $2}' \
  | xargs -n2 sh -c 'kubectl delete pod "$1" -n "$0"'
```

`xargs -I{}` lets you place the argument anywhere:

```bash
kubectl get ns -o name | xargs -I{} kubectl get pods -n {}
```

## Handy one-offs

| Command | Use |
|---------|-----|
| `watch -n2 kubectl get pods` | refresh a get every 2s (or `kubectl get pods -w`) |
| `command \| wc -l` | count lines |
| `Ctrl-c` | cancel the running command |
| `Ctrl-z` then `bg` | suspend and background a command |
| `type kubectl` / `which vim` | confirm a tool is present |

## See also

- [text-tools.md](text-tools.md) — grep/sed/awk that you pipe bash output through
- [jq.md](jq.md) — for JSON output specifically
- [exam-sim/.exam-aliases](../../exam-sim/.exam-aliases) — the `k`, `$do`, `$now` shortcuts referenced here
- [docs/guides/exam-sim-walkthrough.md](../guides/exam-sim-walkthrough.md) — exam practice drills
