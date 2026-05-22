# Stage 06 — ConfigMap & Secret

**Exam focus:** CKAD — ConfigMaps, Secrets, env vs file mounts, immutable configs.

**Goal:** stop hard-coding the SQL connection string in the Deployment. Move it into a Secret. Add a ConfigMap for non-sensitive settings.

---

## ConfigMap vs Secret

| | ConfigMap | Secret |
|--|-----------|--------|
| **For** | Non-sensitive config (log levels, feature flags, URLs) | Sensitive data (passwords, tokens, keys) |
| **Storage** | etcd, plaintext | etcd, base64-encoded (and optionally encrypted at rest — CKS) |
| **Mount as** | env vars or files | env vars or files |
| **Hot-reload** | If mounted as a file, yes. If injected as env, no — needs a Pod restart. | Same |

**Base64 is not encryption.** A Secret in etcd is one `base64 -d` away from plaintext. Encryption-at-rest (`EncryptionConfiguration`) is a separate setup — CKS exam territory.

## Create a ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: incidenthub-config
  namespace: incidenthub
data:
  ASPNETCORE_ENVIRONMENT: Production
  LOG_LEVEL: Information
```

## Create a Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: incidenthub-conn
  namespace: incidenthub
type: Opaque
stringData:
  SQL_CONNECTION_STRING: "Server=mssql.azure-sql.svc.cluster.local,1433;Database=incidenthub;User Id=sa;Password=AksLab!SqlDev1;TrustServerCertificate=True;"
```

`stringData` is a write-only convenience — Kubernetes base64-encodes it for you when storing. When you `get -o yaml` it back, you'll see `data` with the encoded values.

```bash
kubectl apply -f configmap.yaml -f secret.yaml

# Inspect
kubectl -n incidenthub get cm incidenthub-config -o yaml
kubectl -n incidenthub get secret incidenthub-conn -o jsonpath='{.data.SQL_CONNECTION_STRING}' | base64 -d
```

## Reference them from the Deployment

```yaml
spec:
  template:
    spec:
      containers:
        - name: web
          envFrom:
            - configMapRef: { name: incidenthub-config }   # all keys -> env
            - secretRef:    { name: incidenthub-conn }     # all keys -> env
```

Or pick individual keys:

```yaml
          env:
            - name: SQL_CONNECTION_STRING
              valueFrom:
                secretKeyRef: { name: incidenthub-conn, key: SQL_CONNECTION_STRING }
            - name: LOG_LEVEL
              valueFrom:
                configMapKeyRef: { name: incidenthub-config, key: LOG_LEVEL }
```

Apply the change. Because `env` is in the Pod spec, this triggers a rolling update.

## Files instead of env

For TLS certs, JSON config blobs, or anything multi-line, mount as a file:

```yaml
spec:
  template:
    spec:
      containers:
        - name: web
          volumeMounts:
            - name: appsettings
              mountPath: /app/config
              readOnly: true
      volumes:
        - name: appsettings
          configMap:
            name: incidenthub-config
            items:
              - { key: appsettings.json, path: appsettings.json }
```

File mounts are **live**. Update the ConfigMap, the file on disk updates within ~60s (kubelet sync). The app must watch the file or accept the new value on next read.

## Immutable ConfigMaps & Secrets

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: incidenthub-config
immutable: true
data: { ... }
```

Reduces API-server load (kubelet stops watching them) and prevents accidental edits. The trade-off: you have to delete + recreate to change anything. Useful for version-pinned config (e.g. `incidenthub-config-v17`).

## What you learn

- ConfigMaps and Secrets have identical shape and identical Pod-injection mechanics. The only difference is the *intent* (and base64 wrapping).
- `envFrom` injects every key as an env var; `env.valueFrom.secretKeyRef` injects one key.
- Env vars do *not* update live. File mounts do.
- Secrets in etcd are plaintext-equivalent unless encryption-at-rest is configured.
- Stage 14 replaces this Secret with Vault Agent injection — same env vars, but the values come from Vault KV instead of etcd.

## Try this (exam-form)

```bash
# Imperative ConfigMap from literals or a file
kubectl -n incidenthub create configmap incidenthub-config \
  --from-literal=LOG_LEVEL=Information --from-literal=ASPNETCORE_ENVIRONMENT=Production
kubectl -n incidenthub create configmap appsettings --from-file=appsettings.json

# Imperative Secret
kubectl -n incidenthub create secret generic incidenthub-conn \
  --from-literal=SQL_CONNECTION_STRING='Server=...'

# Show all env actually set on a running pod (proves injection worked)
kubectl -n incidenthub exec deploy/incidenthub-web -- env | grep -E '^(SQL_|LOG_|ASPNET)'

# Decode a Secret value
kubectl -n incidenthub get secret incidenthub-conn \
  -o jsonpath='{.data.SQL_CONNECTION_STRING}' | base64 -d ; echo
```

Next — [Stage 07: probes, resources, QoS](07-probes-resources.md).
