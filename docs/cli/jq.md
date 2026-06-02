# jq

**Exam terminal:** ✅ available
**Purpose:** Slice, filter, and reshape JSON — mostly the JSON that `kubectl -o json`
produces — to pull out exactly the value a task asks for.

Many exam questions are really "find the one pod/secret/field that matches a condition".
`kubectl` custom-columns and `-o jsonpath` can do some of this, but `jq` is more powerful
and easier to reason about once you know a handful of filters.

Pipe `kubectl ... -o json` into `jq`:

```bash
kubectl get pods -o json | jq <filter>
```

## The core filters

| Filter | Does |
|--------|------|
| `.` | the whole input (pretty-printed) |
| `.metadata.name` | a field |
| `.items[]` | iterate every element of the `items` array |
| `.items[].metadata.name` | that field from every item |
| `.items[0]` | first element |
| `select(<cond>)` | keep only elements matching a condition |
| `\| length` | count |
| `-r` | **raw** output: strings without quotes (use when feeding another command) |
| `keys` | list the keys of an object |

> `kubectl get <type> -o json` returns a **List** object whose `.items` is the array.
> `kubectl get <type> <name> -o json` returns a **single** object (no `.items`).

## Everyday exam queries

List all pod names in the namespace:

```bash
kubectl get pods -o json | jq -r '.items[].metadata.name'
```

Pods and the node they run on:

```bash
kubectl get pods -o json \
  | jq -r '.items[] | "\(.metadata.name) -> \(.spec.nodeName)"'
```

Find pods that are **not** Running:

```bash
kubectl get pods -A -o json \
  | jq -r '.items[] | select(.status.phase != "Running")
           | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"'
```

Container images used by every pod (handy for CKS image-policy tasks):

```bash
kubectl get pods -A -o json \
  | jq -r '.items[].spec.containers[].image' | sort -u
```

The name of the pod consuming the most restarts:

```bash
kubectl get pods -o json \
  | jq -r '.items
           | max_by(.status.containerStatuses[0].restartCount)
           | .metadata.name'
```

## Decoding Secrets (CKS / CKAD)

Secret values are base64. jq pulls the field, then pipe to `base64 -d`:

```bash
kubectl get secret db-creds -o json | jq -r '.data.password' | base64 -d
```

All keys in a secret at once:

```bash
kubectl get secret db-creds -o json \
  | jq -r '.data | to_entries[] | "\(.key)=\(.value)"'
```

## RBAC and node inspection

ServiceAccount tokens / mounted secrets for a SA:

```bash
kubectl get sa default -o json | jq '.secrets'
```

Node allocatable CPU and memory:

```bash
kubectl get nodes -o json \
  | jq -r '.items[] | "\(.metadata.name) cpu=\(.status.allocatable.cpu) mem=\(.status.allocatable.memory)"'
```

Which nodes carry a given taint:

```bash
kubectl get nodes -o json \
  | jq -r '.items[] | select(.spec.taints != null)
           | "\(.metadata.name): \(.spec.taints[].key)"'
```

## Tips under exam pressure

- Build filters incrementally. Start with `| jq '.items[0]'` to see the shape of one
  object, then drill down field by field.
- Use `-r` whenever the value feeds another command (a name passed to `kubectl delete`,
  a password passed to `base64 -d`). Without it you get quoted strings.
- `select()` takes a boolean: `==`, `!=`, `>`, `and`, `or`, `| test("regex")`.
- If jq feels like too much for a quick lookup, `kubectl get ... -o jsonpath='{...}'`
  is built in and sometimes faster for a single field.

## See also

- [text-tools.md](text-tools.md) — grep/sed/awk for non-JSON output
- [bash.md](bash.md) — piping jq output into loops and xargs
- [docs/guides/exam-sim-walkthrough.md](../guides/exam-sim-walkthrough.md) — exam practice drills
