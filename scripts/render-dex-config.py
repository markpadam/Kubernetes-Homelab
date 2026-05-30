import os, re, string
from pathlib import Path

import os; t = Path(os.environ.get("REPO_ROOT", "/Users/markpadam/Documents/Kubernetes-Homelab") + "/flux/infrastructure/base/identity/dex/config.yaml").read_text()

samba_ip = os.environ.get("SAMBA_IP", "").strip()

# Strip LDAP connector block when SambaAD is not available.
# The markers are indented (inside the YAML data block) — match only those.
if not samba_ip or samba_ip == "<samba-ip>":
    t = re.sub(
        r"[ \t]+# LDAP-CONNECTOR-BEGIN\n.*?[ \t]+# LDAP-CONNECTOR-END\n?",
        "",
        t,
        flags=re.DOTALL,
    )
    print("SambaAD not running — LDAP connector block stripped")
else:
    print(f"SambaAD at {samba_ip} — LDAP connector included")

rendered = string.Template(t).safe_substitute(os.environ)
Path("/tmp/dex-config-rendered.yaml").write_text(rendered)
issuer_line = [l for l in rendered.splitlines() if "issuer:" in l][0].strip()
print("issuer:", issuer_line)
