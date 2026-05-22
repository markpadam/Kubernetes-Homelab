# Stage 02 — Containerise & push to the in-cluster registry

**Exam focus:** CKAD image fundamentals, CKS image hygiene.

**Goal:** turn the three .NET projects into OCI images and push them to the in-cluster Container Registry. Every later stage pulls from this registry.

---

## The Dockerfiles

Look at `src/incidenthub/Dockerfile.web`:

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY src/Web/ ./Web/
RUN dotnet publish Web/IncidentHub.Web.csproj -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
RUN useradd -u 10001 -r app && chown app /app
USER app
COPY --from=build --chown=app /app/publish .
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080
ENTRYPOINT ["dotnet", "IncidentHub.Web.dll"]
```

Three things worth noting for the exam:

| Feature | Why it matters |
|---------|----------------|
| **Multi-stage build** | The `sdk` image is 800 MB. The `aspnet` runtime image is ~220 MB. Only the runtime layer ships. |
| **Non-root user** (`USER app`) | PSS *restricted* (stage 17) refuses to schedule pods that run as root. Bake the non-root user into the image, not the Pod spec — the image is the contract. |
| **Distinct binaries** | Web uses the `aspnet` base image (Kestrel + ASP.NET). Worker and Migrator use the smaller `runtime` image (no HTTP stack). |

## Enable the registry

```bash
./scripts/lab-feature.sh enable container-registry
kubectl get svc -n container-registry
# registry  ClusterIP  10.96.x.y  5000/TCP
```

The registry is exposed at `registry.container-registry.svc.cluster.local:5000` inside the cluster. From the Mac we'll port-forward to push.

## Build & push the three images

```bash
cd src/incidenthub

# Port-forward the registry once for the whole push session
kubectl -n container-registry port-forward svc/registry 5000:5000 &

# Build
docker build -t localhost:5000/incidenthub-web:0.1.0      -f Dockerfile.web      .
docker build -t localhost:5000/incidenthub-worker:0.1.0   -f Dockerfile.worker   .
docker build -t localhost:5000/incidenthub-migrator:0.1.0 -f Dockerfile.migrator .

# Push
docker push localhost:5000/incidenthub-web:0.1.0
docker push localhost:5000/incidenthub-worker:0.1.0
docker push localhost:5000/incidenthub-migrator:0.1.0
```

## Confirm the registry has them

```bash
curl -s http://localhost:5000/v2/_catalog | jq
# { "repositories": ["incidenthub-migrator","incidenthub-web","incidenthub-worker"] }

curl -s http://localhost:5000/v2/incidenthub-web/tags/list | jq
# { "name":"incidenthub-web", "tags":["0.1.0"] }
```

## What you learn

- **Image references are FQDNs** — `registry.container-registry.svc.cluster.local:5000/incidenthub-web:0.1.0`. Pods inside the cluster pull using the in-cluster DNS name. Your laptop pushes using `localhost:5000` thanks to the port-forward. Same registry, two names.
- **Tags are mutable, digests are not** — `:latest` is convenient but dangerous in production. Pin to a digest (`@sha256:…`) for reproducible deploys. The exam asks about this in supply-chain questions.
- **Images are immutable inputs to Kubernetes** — the Pod spec references a name + tag; the runtime resolves to a digest and pulls. Once running, the image cannot change underneath you. To "update" a Pod, you replace it.

## CKS notes — image hygiene

- The Web image is `aspnet:8.0` — pin to a digest in production. `mcr.microsoft.com/dotnet/aspnet:8.0@sha256:...`.
- The Worker image is `runtime:8.0` — same.
- Stage 23 runs `trivy image localhost:5000/incidenthub-web:0.1.0` and `cosign sign` against these images. Note the CVEs reported and the cosign signature flow.

## Try this

```bash
# Inspect a pushed image's layers without pulling it
curl -s http://localhost:5000/v2/incidenthub-web/manifests/0.1.0 \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' | jq

# Delete & re-push to test the registry GC behaviour
docker rmi localhost:5000/incidenthub-web:0.1.0
docker pull localhost:5000/incidenthub-web:0.1.0
```

Next — [Stage 03: first pod](03-pod.md).
