# Scenario Schema Reference

Scenarios are defined in `scenarios.json` as a JSON array. Each object follows the schema below.

## Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Unique identifier, kebab-case (e.g. `cka-rbac-role`) |
| `title` | string | yes | Short display title |
| `exam_track` | string[] | yes | One or more of `"CKA"`, `"CKAD"`, `"CKS"`, `"basics"` |
| `type` | string | yes | `"task"` (hands-on kubectl) or `"mcq"` (multiple choice) |
| `difficulty` | string | yes | `"easy"`, `"medium"`, or `"hard"` |
| `weight` | number | yes | Points value in exam mode (typically 4–8) |
| `namespace` | string | no | Default namespace for the scenario (task type only) |
| `description` | string | yes | Markdown — the scenario question/brief shown to the candidate |
| `hints` | string[] | no | Optional hints shown in practice mode only |
| `setup_commands` | string[] | no | Commands run before the scenario to prepare state |
| `validation_checks` | object[] | yes (task) | Array of check objects (see below) |
| `teardown_commands` | string[] | no | Commands run after the scenario to clean up |
| `choices` | object[] | yes (mcq) | Array of choice objects (see below) |
| `correct_choice` | string | yes (mcq) | The `id` of the correct choice |
| `explanation` | string | no | Shown after MCQ is answered |
| `source` | string | no | `"kubecosh"` if adapted from KubeKosh, omit for original |

## Validation check object (task type)

```json
{
  "command": "kubectl get serviceaccount my-sa -n my-ns -o name",
  "match_type": "contains",
  "expected": "serviceaccount/my-sa",
  "message": "ServiceAccount my-sa not found in namespace my-ns"
}
```

| Field | Values | Description |
|-------|--------|-------------|
| `match_type` | `exact` | stdout must equal `expected` exactly |
| | `contains` | stdout must contain `expected` |
| | `not_contains` | stdout must NOT contain `expected` |
| | `regex` | stdout must match `expected` as a Python regex |
| `command` | string | Shell command run via `subprocess.run` with `shell=True` |
| `expected` | string | Value to match against stdout (stripped) |
| `message` | string | Human-readable failure message shown to the candidate |

## MCQ choice object

```json
{ "id": "a", "text": "The scheduler" }
```

## Difficulty and weight guidelines

| Difficulty | Weight | Target time | Description |
|------------|--------|-------------|-------------|
| `easy` | 4 | 2–3 min | Single resource, straightforward kubectl command |
| `medium` | 6 | 4–6 min | 2–3 sub-tasks, some reasoning required |
| `hard` | 8 | 6–10 min | Multi-step, troubleshooting or complex config |

Killer.sh-style questions are predominantly `hard`. Original scenarios in this set aim for the same bar.

## Example — task scenario

```json
{
  "id": "cka-rbac-role",
  "title": "RBAC: Create a Role and RoleBinding",
  "exam_track": ["CKA", "CKS"],
  "type": "task",
  "difficulty": "medium",
  "weight": 6,
  "namespace": "rbac-test",
  "description": "Create a namespace `rbac-test`. In that namespace create a ServiceAccount named `app-sa`, a Role named `pod-reader` that allows `get`, `list`, and `watch` on `pods`, and a RoleBinding named `app-sa-pod-reader` that binds `pod-reader` to `app-sa`.",
  "hints": [
    "Use `kubectl create serviceaccount` and `kubectl create role` for speed.",
    "RoleBinding subject kind is `ServiceAccount`, not `User`."
  ],
  "setup_commands": ["kubectl create namespace rbac-test --dry-run=client -o yaml | kubectl apply -f -"],
  "validation_checks": [
    {
      "command": "kubectl get serviceaccount app-sa -n rbac-test -o name",
      "match_type": "contains",
      "expected": "serviceaccount/app-sa",
      "message": "ServiceAccount app-sa not found in rbac-test"
    },
    {
      "command": "kubectl get role pod-reader -n rbac-test -o jsonpath='{.rules[0].verbs}'",
      "match_type": "contains",
      "expected": "list",
      "message": "Role pod-reader missing expected verbs"
    },
    {
      "command": "kubectl get rolebinding app-sa-pod-reader -n rbac-test -o jsonpath='{.subjects[0].name}'",
      "match_type": "exact",
      "expected": "app-sa",
      "message": "RoleBinding app-sa-pod-reader not bound to app-sa"
    }
  ],
  "teardown_commands": ["kubectl delete namespace rbac-test --ignore-not-found"]
}
```

## Example — MCQ scenario

```json
{
  "id": "cka-etcd-quorum-mcq",
  "title": "etcd quorum and fault tolerance",
  "exam_track": ["CKA"],
  "type": "mcq",
  "difficulty": "medium",
  "weight": 4,
  "description": "A production etcd cluster has 5 members. What is the maximum number of member failures it can tolerate while maintaining quorum?",
  "choices": [
    { "id": "a", "text": "1" },
    { "id": "b", "text": "2" },
    { "id": "c", "text": "3" },
    { "id": "d", "text": "4" }
  ],
  "correct_choice": "b",
  "explanation": "etcd requires a majority quorum of (n/2)+1 nodes. For 5 members quorum is 3, so 2 failures can be tolerated."
}
```

## Adding new scenarios

1. Add an entry to `scenarios.json` following the schema above.
2. Test it: start the dashboard, navigate to the scenario, complete the task, and click **Check my work**.
3. For task scenarios, also test a deliberate failure to confirm the right check fails.
4. If the scenario is derived from KubeKosh, set `"source": "kubecosh"`. Original scenarios omit the field.
