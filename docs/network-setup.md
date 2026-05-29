# Network Setup — Manual Changes Required

This document covers every manual change needed on the router, Mac Pro, and MacBook to run the lab with real routable IPs. None of these changes are made by `./aks-lab setup` — they are one-time host and network configuration steps.

---

## Network Layout

```
172.16.0.0/16 — Lab address space
│
├── 172.16.0.0/24   Management
│   ├── 172.16.0.1      Router / default gateway
│   ├── 172.16.0.2      dnsmasq DNS (runs on Mac Pro)
│   └── 172.16.0.10     Mac Pro 2013 — primary host IP
│
├── 172.16.1.0/24   Clients / Workstations
│   └── 172.16.1.10     MacBook Pro
│
├── 172.16.3.0/24   Kubernetes — MetalLB service pool  ← routed via Mac Pro
│   ├── 172.16.3.1      NGINX Ingress  (*.aks-lab.local — port 80/443)
│   ├── 172.16.3.2      Reserved (Vault — currently on Mac Pro host at .10:8200)
│   ├── 172.16.3.3      Azure SQL Edge (1433)
│   ├── 172.16.3.4      Service Bus / RabbitMQ (5672, 5300)
│   ├── 172.16.3.5      Container Registry (5000)
│   ├── 172.16.3.6      Cosmos DB (8081, 1234)
│   ├── 172.16.3.7      Argo Workflows (2746)
│   ├── 172.16.3.8      Toolbox SSH (22)
│   ├── 172.16.3.9      Azurite blob storage (10000–10002)
│   ├── 172.16.3.10     Kubernetes Dashboard (443)
│   └── 172.16.3.11–254 Available
│
├── 172.16.4.0/24   Reserved — Kubernetes node IPs (future bare-metal/k3s)
│
└── 172.16.5.0/24+  Available for future zones (IoT, guest, storage, etc.)

192.168.105.0/24 — Lima shared network (NAT'd via Mac Pro — internal only)
    192.168.105.10  samba-ad VM
    192.168.105.11  corp-client VM
```

**Internal ranges — never routed on the physical network:**

| Range | Purpose |
|-------|---------|
| `10.244.0.0/16` | Kubernetes pod CIDR (Minikube internal) |
| `10.96.0.0/12` | Kubernetes ClusterIP CIDR (Minikube internal) |
| `192.168.49.0/24` | Minikube Docker bridge (Mac Pro only) |
| `192.168.105.0/24` | Lima VM network (Mac Pro only, NAT'd) |

---

## How Traffic Flows

```
MacBook → http://grafana.aks-lab.local
  1. DNS: MacBook asks 172.16.0.10 (dnsmasq) → resolves to 172.16.3.1
  2. Packet: SRC=172.16.1.10, DST=172.16.3.1
  3. Router: static route sends 172.16.3.x traffic to 172.16.0.10 (Mac Pro)
  4. Mac Pro: IP forwarding enabled + minikube tunnel route active
  5. Tunnel route: 172.16.3.0/24 → 192.168.49.2 (Minikube Docker bridge)
  6. MetalLB answers ARP for 172.16.3.1, NGINX Ingress handles the request
  7. Response travels back: cluster → Docker bridge → Mac Pro → router → MacBook ✓
```

No port-forwarding. Standard HTTP on port 80, HTTPS on 443.

---

## 1. Router

### Static routes

The router needs to know to send `172.16.3.x` traffic to the Mac Pro (which tunnels it into the cluster). The Lima VM network is NAT'd so it does **not** need a router static route.

| Destination | Next hop | Purpose |
|-------------|----------|---------|
| `172.16.3.0/24` | `172.16.0.10` | Kubernetes MetalLB services |

> The exact menu path depends on your router. Look for **Static Routes**, **Advanced Routing**, or **LAN Routes**.

### DHCP reservations

Assign fixed IPs by MAC address so the static routes stay valid across reboots.

| Device | MAC address | Reserved IP |
|--------|------------|-------------|
| Mac Pro 2013 | *(find below)* | `172.16.0.10` |
| MacBook Pro | *(find below)* | `172.16.1.10` |

**Find MAC address on macOS:**
```bash
# Ethernet (en0)
ifconfig en0 | grep ether

# Or via System Preferences → Network → Advanced → Hardware tab
```

---

## 2. Mac Pro (one-time)

### 2a. Set a static IP (if not using DHCP reservation)

Prefer a DHCP reservation in the router. If you need to set it manually:

**System Preferences → Network → Ethernet → Configure IPv4: Manually**

| Field | Value |
|-------|-------|
| IP Address | `172.16.0.10` |
| Subnet Mask | `255.255.255.0` |
| Router | `172.16.0.1` |
| DNS Server | `172.16.0.1` (router) |

### 2b. Enable IP forwarding

Allows the Mac Pro to route packets between the MacBook subnet and the MetalLB subnet.

```bash
# Apply immediately
sudo sysctl -w net.inet.ip.forwarding=1

# Persist across reboots
echo "net.inet.ip.forwarding=1" | sudo tee -a /etc/sysctl.conf
```

### 2c. Install dnsmasq

Provides wildcard DNS so `*.aks-lab.local` resolves to the NGINX Ingress IP (`172.16.3.1`) and direct service names resolve to their MetalLB IPs.

```bash
brew install dnsmasq

# Install the lab config fragment
sudo cp IaC/macos/dnsmasq-aks-lab.conf /usr/local/etc/dnsmasq.d/aks-lab.conf

# Start and enable on boot
sudo brew services start dnsmasq
```

Verify dnsmasq is answering:
```bash
dig grafana.aks-lab.local @127.0.0.1
# Should return 172.16.3.1

dig corp.internal @127.0.0.1
# Should return 192.168.105.10
```

### 2d. Install the minikube tunnel launchd daemon

Run after `./aks-lab setup` has completed at least once (the `aks-lab` minikube profile must exist first).

```bash
sudo cp IaC/macos/com.lab.minikube-tunnel.plist /Library/LaunchDaemons/
sudo launchctl load /Library/LaunchDaemons/com.lab.minikube-tunnel.plist
```

This keeps `minikube tunnel` running at boot so MetalLB IPs remain routable without any manual intervention.

Check it is running:
```bash
sudo launchctl list | grep minikube-tunnel
cat /tmp/minikube-tunnel.log
```

To restart it manually:
```bash
sudo launchctl kickstart -k system/com.lab.minikube-tunnel
```

To uninstall:
```bash
sudo launchctl unload /Library/LaunchDaemons/com.lab.minikube-tunnel.plist
sudo rm /Library/LaunchDaemons/com.lab.minikube-tunnel.plist
```

### 2e. macOS Firewall (if enabled)

If **System Preferences → Security & Privacy → Firewall** is on, allow incoming connections for:

| App / binary | Why |
|-------------|-----|
| `dnsmasq` | DNS queries from MacBook on port 53/UDP |
| `vault` | Vault UI/API on port 8200 |
| Docker Desktop | Minikube cluster traffic |

Add via **Firewall Options → +** and select each binary, or temporarily disable the firewall during initial setup to confirm everything works first.

---

## 3. MacBook (one-time)

### 3a. DNS resolver

Tells macOS to send `*.aks-lab.local` and `*.corp.internal` queries to the Mac Pro's dnsmasq rather than the default DNS server.

```bash
sudo mkdir -p /etc/resolver

# aks-lab web services and cluster IPs
echo "nameserver 172.16.0.10" | sudo tee /etc/resolver/aks-lab.local

# Active Directory domain (forwarded to samba-ad via dnsmasq on Mac Pro)
echo "nameserver 172.16.0.10" | sudo tee /etc/resolver/corp.internal
```

Verify DNS resolution from the MacBook:
```bash
# Web service — should return 172.16.3.1
dig grafana.aks-lab.local

# Direct service — should return 172.16.3.3
dig sql.aks-lab.local

# AD domain — should return 192.168.105.10
dig corp.internal
```

### 3b. kubectl access

Generate a kubeconfig on the Mac Pro with the external API server address, then copy it to the MacBook.

**On the Mac Pro:**
```bash
minikube -p aks-lab kubectl -- config view --flatten \
  | sed 's|https://192.168.49.2:8443|https://172.16.0.10:8443|g' \
  > /tmp/aks-lab-kubeconfig.yaml
```

Open `/tmp/aks-lab-kubeconfig.yaml` and add `insecure-skip-tls-verify: true` to the cluster entry (the API server TLS cert was issued for the internal Minikube IP, not `172.16.0.10`):

```yaml
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://172.16.0.10:8443
  name: aks-lab
```

**Copy to MacBook:**
```bash
scp user@172.16.0.10:/tmp/aks-lab-kubeconfig.yaml ~/.kube/aks-lab-config
```

**Use it:**
```bash
export KUBECONFIG=~/.kube/aks-lab-config
kubectl get nodes
```

---

## 4. Verification Checklist

Run these from the **MacBook** after all changes above are in place.

```bash
# Mac Pro is reachable
ping -c 3 172.16.0.10

# DNS resolves correctly
dig grafana.aks-lab.local          # → 172.16.3.1
dig sql.aks-lab.local              # → 172.16.3.3
dig corp.internal                  # → 192.168.105.10

# MetalLB ingress reachable (run after ./aks-lab setup on Mac Pro)
curl -s -o /dev/null -w "%{http_code}" http://172.16.3.1
# → 404 (NGINX default — no host header, but ingress is alive)

# Web UI via DNS + ingress (no port number needed)
curl -s -o /dev/null -w "%{http_code}" http://grafana.aks-lab.local
# → 302 (redirect to Grafana login)

# Vault on Mac Pro host
curl http://172.16.0.10:8200/v1/sys/health
# → {"initialized":true,"sealed":false,...}

# kubectl
kubectl --kubeconfig ~/.kube/aks-lab-config get nodes
# → 3 nodes, all Ready
```
