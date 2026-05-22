# Stage 14 — Vault Agent injection

**Exam focus:** CKS — secrets at rest, dynamic secrets, workload identity.

**Goal:** stop storing connection strings in a Kubernetes Secret. Move them to Vault KV; let Vault Agent inject them into the Pod at start.

---

## Why

A Kubernetes Secret is base64 in etcd. Anyone with `get secrets` RBAC can read it. Anyone with etcd access can read it. Stage 6's `incidenthub-conn` Secret is fine for the emulator, but real prod credentials don't belong there.

Vault gives us:

- **Centralised storage** outside etcd, with audit logs of every read.
- **Workload-identity-based auth** — pods authenticate with their ServiceAccount JWT, no static credentials in the pod spec.
- **Dynamic credentials** — Vault can issue short-lived DB credentials per pod (not configured here, but a Vault staple).

The lab's Vault dev server, KV engine, Kubernetes auth backend, and `azure-services` policy were all set up by Terraform (see [docs/iac/terraform.md](../../iac/terraform.md)).

## Put the connection strings in Vault

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

vault kv put kv/incidenthub \
  sql_connection_string="Server=mssql.azure-sql.svc.cluster.local,1433;Database=incidenthub;User Id=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;" \
  blob_connection_string="DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1;" \
  servicebus_connection_string="Endpoint=sb://servicebus.service-bus.svc.cluster.local;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;" \
  cosmos_connection_string="AccountEndpoint=http://cosmosdb.cosmos-db.svc.cluster.local:8081/;AccountKey=C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==;"

vault kv get kv/incidenthub
```

## Create a Vault policy + Kubernetes role

A scoped policy for IncidentHub:

```bash
vault policy write incidenthub - <<'HCL'
path "kv/data/incidenthub" {
  capabilities = ["read"]
}
HCL

vault write auth/kubernetes/role/incidenthub \
  bound_service_account_names=incidenthub \
  bound_service_account_namespaces=incidenthub \
  policies=incidenthub \
  ttl=1h
```

## Annotate the Deployment for Vault Agent

The Vault Agent Injector is a mutating webhook installed alongside Vault. Annotations on the Pod spec opt-in:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: incidenthub-web, namespace: incidenthub }
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "incidenthub"
        vault.hashicorp.com/agent-inject-secret-config.env: "kv/data/incidenthub"
        vault.hashicorp.com/agent-inject-template-config.env: |
          {{- with secret "kv/data/incidenthub" -}}
          export SQL_CONNECTION_STRING={{ .Data.data.sql_connection_string }}
          export BLOB_CONNECTION_STRING={{ .Data.data.blob_connection_string }}
          export SERVICEBUS_CONNECTION_STRING={{ .Data.data.servicebus_connection_string }}
          export COSMOS_CONNECTION_STRING={{ .Data.data.cosmos_connection_string }}
          {{- end }}
    spec:
      serviceAccountName: incidenthub
      containers:
        - name: web
          image: ...
          command: ["/bin/sh", "-c"]
          args: ["source /vault/secrets/config.env && exec dotnet IncidentHub.Web.dll"]
```

Two new mechanics:

1. **Mutating webhook** inserts a `vault-agent-init` init container and a `vault-agent` sidecar (the second renders the file template).
2. **File-based secrets** at `/vault/secrets/config.env`. The container `source`s the file before `exec`ing the app.

## Apply and observe

```bash
kubectl apply -f web-deployment.yaml
kubectl -n incidenthub get pods -l component=web
# Each pod now has 3 containers: vault-agent-init (completed), vault-agent (sidecar), web.

kubectl -n incidenthub logs -l component=web -c vault-agent
# auth.handler: authenticated to Vault using kubernetes auth method
# template.runner: rendering /vault/secrets/config.env

kubectl -n incidenthub exec deploy/incidenthub-web -c web -- env | grep _CONNECTION_STRING
# (still set — sourced from the file)
```

Delete the Kubernetes Secret now — the pod doesn't need it:

```bash
kubectl -n incidenthub delete secret incidenthub-conn
kubectl -n incidenthub rollout restart deploy/incidenthub-web   # confirm it still starts
```

## Dynamic secrets (preview)

What we did above is **static** — Vault returns the same KV value each time. The more powerful Vault pattern is **dynamic**: ask Vault for a fresh DB user with a 1-hour TTL. The pod gets credentials no human ever saw.

That's outside this lab's scope but the CKS exam expects you to know the concept. The auth + injection mechanics are identical; only the secrets engine changes (`database` instead of `kv`).

## What you learn

- Vault decouples "where the secret lives" from "how the app reads it." The app still reads env vars — Vault Agent just fills them differently.
- Kubernetes auth lets pods authenticate with their ServiceAccount JWT — no API keys baked into the image or pod spec.
- The Pod's ServiceAccount is the workload identity. Granular Vault policies map 1:1 to ServiceAccount + namespace pairs.
- Vault Agent runs as a sidecar — that's how it stays close to the workload and can renew tokens transparently.

## CKS notes

- **No more raw Secret YAML** for credentials. Even with encryption-at-rest, the surface of "anyone with RBAC on Secret" is larger than "anyone in this namespace's ServiceAccount."
- **Short TTLs.** `ttl=1h` on the Vault role means a compromised pod token expires fast.
- **Audit.** Vault logs every secret read. Kubernetes Secrets do not.
- **Bound SA namespace + name** — restrict to specific SAs, never use `*` in production.

## Try this (exam-form)

```bash
# Delete the rendered file, watch agent re-render
kubectl -n incidenthub exec deploy/incidenthub-web -c vault-agent -- ls /vault/secrets

# Watch the agent renew on TTL
kubectl -n incidenthub logs deploy/incidenthub-web -c vault-agent --tail=20 -f

# Read what Vault sees (root token — lab only!)
vault kv get -format=json kv/incidenthub | jq '.data.data | keys'

# Quick check that the pod's SA can authenticate to Vault
TOKEN=$(kubectl -n incidenthub create token incidenthub)
curl -sf --request POST \
  --data "{\"jwt\":\"$TOKEN\",\"role\":\"incidenthub\"}" \
  $VAULT_ADDR/v1/auth/kubernetes/login | jq '.auth.client_token'
```

Next — [Stage 15: ServiceAccount, Role, RoleBinding](15-rbac.md).
