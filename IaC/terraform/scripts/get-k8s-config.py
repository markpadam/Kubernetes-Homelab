#!/usr/bin/env python3
"""
Reads the Vault reviewer service account CA certificate and JWT from Minikube
and prints them as a JSON object for Terraform's external data source.

Called by: data "external" "k8s_vault_config" in main.tf
Arguments: <minikube-profile>  (default: aks-lab)

Azure equivalent: reading the OIDC issuer metadata that Azure AD uses to
validate workload identity tokens — a read-only lookup against the cluster
that Vault uses to verify that pod service account tokens are genuine.

The external data source protocol requires:
  - Input:  JSON object on stdin (ignored here)
  - Output: flat JSON object on stdout (all values must be strings)
  - Errors: non-zero exit code + message on stderr
"""

import subprocess
import json
import base64
import sys


def get_secret_field(profile: str, field: str) -> str:
    """Extract and base64-decode a field from the vault-reviewer-token secret."""
    raw = subprocess.check_output(
        [
            "kubectl", "--context", profile,
            "get", "secret", "vault-reviewer-token",
            "-n", "kube-system",
            "-o", f"jsonpath={{.data.{field}}}",
        ],
        stderr=subprocess.PIPE,
    ).decode().strip()

    if not raw:
        raise RuntimeError(
            f"Field '{field}' in vault-reviewer-token is empty. "
            "Ensure null_resource.k8s_vault_reviewer has completed successfully."
        )

    return base64.b64decode(raw).decode()


def main() -> None:
    profile = sys.argv[1] if len(sys.argv) > 1 else "aks-lab"

    try:
        # The CA certificate is used by Vault to verify TLS connections to the
        # Kubernetes API server — equivalent to the trusted root CA that Azure AD
        # uses when validating tokens against the AKS OIDC endpoint.
        ca_cert = get_secret_field(profile, r"ca\.crt")

        # The reviewer JWT is the token Vault presents to the Kubernetes
        # TokenReview API to verify a pod's service account token.
        # Azure equivalent: the managed identity credential Azure uses internally
        # when validating workload identity tokens on behalf of Key Vault.
        token = get_secret_field(profile, "token")

    except subprocess.CalledProcessError as exc:
        print(
            f"ERROR: kubectl failed — is the '{profile}' context reachable?\n"
            f"{exc.stderr.decode()}",
            file=sys.stderr,
        )
        sys.exit(1)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    # Terraform external data source requires a flat JSON object.
    print(json.dumps({"ca_cert": ca_cert, "token": token}))


if __name__ == "__main__":
    main()
