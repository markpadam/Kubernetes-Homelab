# Stage 23 — Supply chain: Trivy + Cosign

**Exam focus:** CKS — image scanning, image signing, admission policy.

**Goal:** scan IncidentHub images for CVEs, sign them with Cosign, and refuse unsigned images at admission.

---

## The supply chain threat model

| Threat | Mitigation |
|--------|------------|
| Base image has a known CVE | Scan with Trivy in CI; gate the build |
| Attacker swaps a registry image | Sign with Cosign; verify on admission |
| Tampered Dockerfile / build step | Provenance (SLSA, Sigstore) and reproducible builds |
| Misconfigured RBAC ships to prod | Manifest-level scanning (kubescape, kube-linter, Trivy config scan) |

CKS focuses on the first two. SLSA is great context but isn't on the syllabus.

## Trivy — vulnerability scanning

```bash
brew install trivy

# Scan an image
trivy image localhost:5000/incidenthub-web:0.1.0
# CRITICAL: x  HIGH: y  MEDIUM: z  LOW: ...

# Just the unfixed CRITICALs (fail your CI on these)
trivy image --severity CRITICAL --ignore-unfixed --exit-code 1 \
  localhost:5000/incidenthub-web:0.1.0

# Scan the filesystem of a project (no image needed)
trivy fs src/incidenthub/

# Scan Kubernetes manifests for misconfig
trivy config helm/incidenthub/
```

The aspnet base image often has medium CVEs in glibc; pin to a digest and bump regularly. A clean image is rare — what matters is "no CRITICAL/HIGH older than X days."

## Cosign — image signing

```bash
brew install cosign

# Generate a keypair once
cosign generate-key-pair                # cosign.key + cosign.pub

# Sign the image (rev push)
cosign sign --key cosign.key \
  localhost:5000/incidenthub-web:0.1.0

# Verify
cosign verify --key cosign.pub \
  localhost:5000/incidenthub-web:0.1.0
```

The signature is stored as an OCI artifact alongside the image — a `:.sig` tag pointing at the image's digest.

For keyless signing (Sigstore/Fulcio), there are no keys — just an OIDC identity. The signature ties the image to "whoever logged in at sign time."

## Enforcing signatures at admission

The signing only matters if the cluster *refuses* unsigned images. Three options:

| Tool | How |
|------|-----|
| **Kyverno** | `ClusterPolicy` with `validateImages` rule |
| **OPA/Gatekeeper** | ConstraintTemplate calling Cosign |
| **sigstore-policy-controller** | Native Cosign admission, simplest |

### Kyverno example

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: verify-incidenthub-images }
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-signature
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [incidenthub]
      verifyImages:
        - imageReferences:
            - "registry.container-registry.svc.cluster.local:5000/incidenthub-*:*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                      -----END PUBLIC KEY-----
```

Apply, then push an unsigned image and try to deploy — Kyverno's webhook rejects it.

## Image provenance — SBOM

```bash
# Generate a Software Bill of Materials
trivy image --format cyclonedx --output sbom.json localhost:5000/incidenthub-web:0.1.0

# Attach the SBOM to the image as an attestation
cosign attest --key cosign.key --predicate sbom.json --type cyclonedx \
  localhost:5000/incidenthub-web:0.1.0
```

The SBOM travels with the image — auditors can reproduce "what's actually in this thing" without re-running the build.

## In CI

A typical IncidentHub build pipeline (GitHub Actions, Azure DevOps, etc):

1. `docker build`
2. `trivy image --exit-code 1 --severity HIGH,CRITICAL`
3. `docker push`
4. `cosign sign --key $COSIGN_KEY`
5. `cosign attest --predicate sbom.json`

…and the cluster's Kyverno policy refuses anything that's missing step 4.

## What you learn

- **Scanning** is detection. **Signing + admission** is prevention. You want both.
- Pin base images to digests, not tags. Tags are mutable.
- The cluster has to enforce signature checks for them to matter — generate the signatures *and* deploy the admission policy.
- SBOMs are how you answer "what changed?" between two versions of the same image without rebuilding.

## Try this (exam-form)

```bash
# Trivy in 'sbom' mode
trivy image --format spdx-json -o sbom.spdx.json localhost:5000/incidenthub-web:0.1.0

# Quick CVE summary for review
trivy image --severity CRITICAL,HIGH --format table localhost:5000/incidenthub-web:0.1.0

# Verify a signed image refuses if you tamper
docker pull localhost:5000/incidenthub-web:0.1.0
docker tag localhost:5000/incidenthub-web:0.1.0 localhost:5000/incidenthub-web:tampered
docker push localhost:5000/incidenthub-web:tampered
cosign verify --key cosign.pub localhost:5000/incidenthub-web:tampered
# (no matching signature)
```

Next — [Stage 24: Observability](24-observability.md).
