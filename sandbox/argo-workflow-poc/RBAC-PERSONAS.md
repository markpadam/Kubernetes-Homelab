# Argo Workflows RBAC Personas

Three-tier RBAC model for UI access: Admin (full control), Operator (view + submit), Viewer (read-only).

## Personas Overview

| Persona | Level | Permissions | Deployment | Azure Group | Precedence |
|---------|-------|-------------|------------|-------------|------------|
| **Admin** | L3 | Full CRUD | Step 7 / Folder `7-rbac-ui-admin` | `5b8d3623-9aa5-4fcd-9d83-21e1426c8e6f` | 100 (highest) |
| **Operator** | L2 | View + Submit | Step 8 / Folder `8-rbac-ui-operator` | `973c344f-785f-4d12-b07e-43fbd3401fa5` | 50 |
| **Viewer** | L1 | Read-only | Step 9 / Folder `9-rbac-ui-viewer` | `973c344f-785f-4d12-b07e-43fbd3401fa5` | 0 (lowest) |

**Architecture**: All personas use cross-namespace RBAC (ServiceAccount in `jeragm`, Role in `ddh`).

## Permissions Matrix

| Permission | Viewer (L1) | Operator (L2) | Admin (L3) |
|------------|-------------|---------------|------------|
| View workflows/templates/crons | ✅ | ✅ | ✅ |
| View pod logs | ✅ | ✅ | ✅ |
| Submit workflows | ❌ | ✅ | ✅ |
| Edit/Delete templates | ❌ | ❌ | ✅ |
| Edit/Delete cronworkflows | ❌ | ❌ | ✅ |
| Delete workflows | ❌ | ❌ | ❌ |

**Admin**: `get, list, watch, create, patch, update` on workflows, workflowtemplates, cronworkflows  
**Operator**: `get, list, watch, create` on workflows; `get, list, watch` on workflowtemplates, cronworkflows  
**Viewer**: `get, list, watch` on all resources (read-only)

## RBAC Precedence

Higher number = higher priority. If user is in multiple groups, **highest precedence wins**.

Example: User in Operator (50) + Viewer (0) groups → Gets **Operator** permissions.

⚠️ **Current Issue**: Operator and Viewer use same Azure group (`973c344f...`). All users get Operator permissions. Create separate groups for proper RBAC.

## Configuration

### Update Azure Groups (Optional)

Edit the YAML files to use separate Azure groups:

**Example: Operator** (`8-rbac-ui-operator/ddh-operator.yaml`):
```yaml
annotations:
  workflows.argoproj.io/rbac-rule: "'<operator-group-id>' in groups"
  workflows.argoproj.io/rbac-rule-precedence: "50"
```

## Login to Argo UI

```powershell
# Port-forward
kubectl -n jeragm port-forward deployment/argo-server 2746:2746
```

Open: https://localhost:2746

**Azure SSO Authentication**  
Click "Login with SSO" → Authenticate with Azure Entra ID

Your permissions are determined by Azure group membership:
- **Admin** (L3): Group `5b8d3623-9aa5-4fcd-9d83-21e1426c8e6f` (precedence 100)
- **Operator** (L2): Group `973c344f-785f-4d12-b07e-43fbd3401fa5` (precedence 50)
- **Viewer** (L1): Group `973c344f-785f-4d12-b07e-43fbd3401fa5` (precedence 0)

## Verification

```powershell
# Check ServiceAccounts
kubectl get sa -n jeragm | Select-String ddh-ui

# Check Roles
kubectl get role -n ddh | Select-String ddh-ui

# Check RoleBindings (cross-namespace)
kubectl get rolebinding -n ddh | Select-String ddh-ui

# Inspect permissions
kubectl describe role -n ddh ddh-ui-admin-ddh
kubectl describe role -n ddh ddh-ui-operator-ddh
kubectl describe role -n ddh ddh-ui-viewer-ddh
```

## Common Issues

**"Forbidden" error**: User not in configured Azure group or RBAC annotation missing  
**Wrong permissions**: Check precedence values and Azure group membership  

---

**Summary**: Three personas provide flexible UI access with Admin (full CRUD), Operator (view + submit), and Viewer (read-only) permissions using cross-namespace RBAC and Azure SSO.
