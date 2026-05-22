# Stage 09 — Azurite blob: attachments

**Exam focus:** CKAD — env-based config, multi-store apps.

**Goal:** add a second connection string so file attachments upload to Azurite. Confirm the Pod picks up an additional Secret key without code changes.

---

## What Azurite is

The official Microsoft emulator for Azure Storage — Blob, Queue, Table APIs. The SDK calls are identical to real Azure; only the connection string differs. See [docs/services/azurite.md](../../services/azurite.md).

```bash
kubectl -n azure-storage get deploy,svc
# azurite ClusterIP at port 10000 (blob), 10001 (queue), 10002 (table)
```

## The well-known connection string

```text
DefaultEndpointsProtocol=http;
AccountName=devstoreaccount1;
AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;
BlobEndpoint=http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1;
```

These are the published Azurite test credentials — safe to commit. In production this becomes a real Azure Storage account connection string injected by Vault (stage 14).

## Add to the Secret

Patch the existing Secret to add the second key:

```bash
kubectl -n incidenthub patch secret incidenthub-conn --type=merge -p \
  '{"stringData":{"BLOB_CONNECTION_STRING":"DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1;"}}'
```

## Inject into the Pod

The Web Deployment already uses `envFrom: secretRef`, so the new key shows up automatically — but env vars don't refresh in a running pod. Roll the Deployment:

```bash
kubectl -n incidenthub rollout restart deploy/incidenthub-web
kubectl -n incidenthub rollout status deploy/incidenthub-web
```

`rollout restart` triggers a new ReplicaSet without changing the spec — useful for re-reading Secrets, picking up updated images on `:latest`, etc.

## Verify

```bash
# Confirm both env vars present
kubectl -n incidenthub exec deploy/incidenthub-web -- env | grep _CONNECTION_STRING
# BLOB_CONNECTION_STRING=...
# SQL_CONNECTION_STRING=...

# Open the UI and upload an attachment
kubectl -n incidenthub port-forward svc/incidenthub-web 8080:80
# http://localhost:8080 — file an incident with a file attachment
```

The Web pod's `AttachmentStore` (in `src/incidenthub/src/Web/Services/AttachmentStore.cs`) creates the `attachments` container on first use, then uploads each file as a unique blob.

## Inspect from inside the cluster

```bash
# Run Azure CLI in a debug pod (corp-client also has it)
kubectl -n toolbox exec -it deploy/toolbox -- bash
# inside:
export AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://azurite.azure-storage.svc.cluster.local:10000/devstoreaccount1;"
az storage blob list --container-name attachments -o table
```

## What you learn

- Adding a second backing service is "add a Secret key + roll the Pod." The app's contract (env vars) absorbs it.
- `rollout restart` is the idiomatic way to make a Deployment re-pull config without changing the spec.
- The same Azurite Service is reachable from every namespace via cluster DNS — that's why we don't run Azurite in `incidenthub`.
- ClusterIP Services scope to the cluster, not the namespace. Namespacing is for organisation and policy, not network isolation. **NetworkPolicy** (stage 16) is what restricts cross-namespace traffic.

## Try this (exam-form)

```bash
# Add a single key to a Secret without rewriting it
kubectl -n incidenthub patch secret incidenthub-conn --type=merge \
  -p '{"stringData":{"FEATURE_FOO":"true"}}'

# Verify the key is present (encoded form)
kubectl -n incidenthub get secret incidenthub-conn -o jsonpath='{.data}' | jq 'keys'

# rollout restart — the right way to re-read Secrets/ConfigMaps as env vars
kubectl -n incidenthub rollout restart deploy/incidenthub-web

# Tail logs across all pods of the Deployment
kubectl -n incidenthub logs -l app.kubernetes.io/name=incidenthub,component=web -f --tail=20
```

Next — [Stage 10: Service Bus — async worker](10-service-bus.md).
