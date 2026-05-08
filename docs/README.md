# Kubernetes AKS Lab — Minikube Setup

A local Kubernetes lab running on Minikube that simulates an AKS environment with multi-node clustering, ingress, persistent storage, and monitoring.

**Requirements:** macOS, Docker Desktop, Minikube, kubectl, Helm

---

## Step 1 — Start a Multi-Node Cluster

Start a 3-node cluster (1 control plane + 2 workers) using the `aks-lab` profile to keep it isolated from other Minikube environments.

```bash
minikube start \
  --driver=docker \
  --nodes=3 \
  --cpus=2 \
  --memory=4096 \
  --profile=aks-lab \
  --kubernetes-version=v1.29.0
```

Verify all nodes are up:

```bash
minikube node list -p aks-lab
kubectl get nodes
```

Expected output: 3 nodes, all in `Ready` state.

---

## Step 2 — Enable Ingress / Load Balancing

Enable the NGINX ingress controller (the same default as AKS):

```bash
minikube addons enable ingress -p aks-lab
```

For `LoadBalancer` type services to receive an external IP (equivalent to Azure Load Balancer in AKS), run the following in a **separate terminal and leave it running** for the duration of your lab session:

```bash
minikube tunnel -p aks-lab
```

> **Note:** `minikube tunnel` requires sudo on macOS and must stay open. If you close it, LoadBalancer services will lose their external IP.

---

## Step 3 — Enable Persistent Storage

Enable the storage provisioner and CSI hostpath driver to simulate AKS `managed-csi` storage:

```bash
minikube addons enable storage-provisioner -p aks-lab
minikube addons enable volumesnapshots -p aks-lab
minikube addons enable csi-hostpath-driver -p aks-lab
```

Set the CSI hostpath driver as the default StorageClass and remove the default flag from the old one:

```bash
kubectl patch storageclass csi-hostpath-sc \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl patch storageclass standard \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

Verify the default StorageClass:

```bash
kubectl get storageclass
```

`csi-hostpath-sc` should show `(default)`.

---

## Step 4 — Install Monitoring (Prometheus + Grafana)

Add the Prometheus community Helm chart and install the `kube-prometheus-stack`, which includes Prometheus, Grafana, and pre-built Kubernetes dashboards:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=admin123
```

Wait for all pods to be ready:

```bash
kubectl get pods -n monitoring -w
```

Access Grafana in your browser:

```bash
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
```

Open `http://localhost:3000` and log in with `admin` / `admin123`. Kubernetes cluster dashboards are pre-loaded.

---

## Step 5 — Deploy the Demo App (TaskFlow)

Deploy the multi-tier TaskFlow app to validate the full stack — it exercises persistent storage, load balancing, ingress, and autoscaling in one shot.

```bash
kubectl apply -f k8s/
```

Watch all pods come up (takes ~60–90 seconds):

```bash
kubectl get pods -n taskapp -w
```

Add the local hostname so your browser can resolve it:

```bash
echo "$(minikube ip -p aks-lab)  taskapp.local" | sudo tee -a /etc/hosts
```

Open the app at **http://taskapp.local**

### Validate each lab feature

| Feature | Command |
|---|---|
| Multi-node pod spread | `kubectl get pods -n taskapp -o wide` |
| Persistent storage | Delete the postgres pod — data survives |
| Load balancing | UI shows which backend pod is serving |
| HPA autoscaling | `kubectl get hpa -n taskapp` |
| Ingress routing | `curl http://taskapp.local/api/health` |

---

## Day-to-Day Commands

```bash
# Stop the lab without destroying it
minikube stop -p aks-lab

# Start it again
minikube start -p aks-lab

# SSH into a worker node
minikube ssh -p aks-lab -n aks-lab-m02

# Check all addon status
minikube addons list -p aks-lab

# Open the Kubernetes dashboard
minikube dashboard -p aks-lab
```

---

## Teardown

```bash
# Remove just the demo app
kubectl delete namespace taskapp

# Destroy the entire cluster
minikube delete -p aks-lab
```

---

## AKS Feature Mapping

| AKS Feature | Minikube Equivalent |
|---|---|
| Azure Load Balancer | `minikube tunnel` |
| managed-csi StorageClass | csi-hostpath-driver |
| Azure Monitor | Prometheus + Grafana |
| Horizontal Pod Autoscaler | metrics-server addon |
| NGINX Ingress Controller | ingress addon |
| Multi-node node pools | `--nodes=3` flag |
