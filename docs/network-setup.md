# Network Setup — Remote Access from the MacBook & iPad

This lab runs on the **Mac Pro** (Intel, macOS 12 Monterey) using **Colima** for
the Docker daemon and **minikube (docker driver)** for the cluster. By default
everything is reachable only on the Mac Pro itself, because `minikube tunnel`
binds ingress on `127.0.0.1`. This guide makes the lab reachable from the
**MacBook** (or any machine on the LAN).

Most of it is automated by **`./aks-lab publish`**. Only the two MacBook-side
steps (a DNS resolver entry and copying the kubeconfig) are manual.

---

## Why not "routable MetalLB IPs"?

An earlier design tried to route the MetalLB pool (`172.16.3.0/24`) to the
cluster via a host route `172.16.3.0/24 → 192.168.49.2`. **That cannot work
under Colima:** the minikube bridge (`192.168.49.2`) lives *inside* the Colima
QEMU VM, so it isn't reachable from the Mac Pro host or the router. Instead we
publish via the Mac Pro's own LAN IP, which is always reachable and needs no
router changes.

---

## How traffic flows

```text
MacBook → http://grafana.aks-lab.local
  1. DNS: MacBook's /etc/resolver/aks-lab.local → Mac Pro (LAB_HOST_IP)
          dnsmasq on the Mac Pro answers *.aks-lab.local = LAB_HOST_IP
  2. Connect: MacBook → LAB_HOST_IP:80
  3. Mac Pro: socat forwarder (com.lab.publish) LAB_HOST_IP:80 → 127.0.0.1:80
  4. minikube tunnel: 127.0.0.1:80 → NGINX ingress in the cluster
  5. NGINX routes by Host header → Grafana
```

The Kubernetes API (`:8443`) and Vault (`:8200`) already bind `0.0.0.0`, so they
only need DNS + (for kubectl) an external kubeconfig — no forwarder.

---

## 1. Mac Pro — stable IP (one-time)

`./aks-lab publish` uses the Mac Pro's current LAN IP (`LAB_HOST_IP`). Give it a
stable address so it survives reboots — prefer a **DHCP reservation** on the
router (by the Mac Pro's `en0` MAC: `ifconfig en0 | grep ether`), or set a
manual IP in **System Preferences → Network → Ethernet**.

You can override detection with `LAB_HOST_IP=... ./aks-lab publish`.

---

## 2. Mac Pro — publish the lab

```bash
# Install socat once (macOS 12 → MacPorts; otherwise Homebrew)
sudo port install socat        # or: brew install socat

# After ./aks-lab setup (or resume) has the cluster + tunnel up:
./aks-lab publish
```

`./aks-lab publish` (idempotent — re-run after enabling/disabling components):

- verifies which ports `minikube tunnel` is serving on `127.0.0.1`,
- installs a launchd daemon (`com.lab.publish`) that socat-forwards
  `LAB_HOST_IP:<port> → 127.0.0.1:<port>` for ingress `80/443` and any enabled
  non-HTTP services (`1433` SQL, `5000` registry, `5672` Service Bus, `8081`
  Cosmos, `10000-10002` Azurite),
- writes the dnsmasq config so `*.aks-lab.local` resolves to `LAB_HOST_IP` (and
  `corp.internal` to the SambaAD VM when enabled),
- generates an external kubeconfig at `/tmp/aks-lab-kubeconfig.yaml`,
- prints the MacBook-side steps below.

### macOS firewall

If **System Preferences → Security & Privacy → Firewall** is on, allow incoming
connections for `socat`, `dnsmasq`, and `vault` (or disable the firewall while
you confirm everything works).

---

## 3. MacBook — point DNS + kubectl at the Mac Pro (one-time)

Replace `<LAB_HOST_IP>` with the Mac Pro's LAN IP (printed by `publish`).

```bash
sudo mkdir -p /etc/resolver
echo "nameserver <LAB_HOST_IP>" | sudo tee /etc/resolver/aks-lab.local
# Only if the SambaAD identity stack is enabled:
echo "nameserver <LAB_HOST_IP>" | sudo tee /etc/resolver/corp.internal

# kubectl (the API cert already includes LAB_HOST_IP, so no --insecure needed)
scp <you>@<LAB_HOST_IP>:/tmp/aks-lab-kubeconfig.yaml ~/.kube/aks-lab-config
KUBECONFIG=~/.kube/aks-lab-config kubectl get nodes
```

---

## 4. Verification (run from the MacBook)

```bash
ping -c3 <LAB_HOST_IP>                                   # Mac Pro reachable
dig grafana.aks-lab.local                                 # → <LAB_HOST_IP>
curl -s -o /dev/null -w "%{http_code}\n" http://grafana.aks-lab.local   # 302
curl -s http://<LAB_HOST_IP>:8200/v1/sys/health           # Vault (if enabled)
nc -z <LAB_HOST_IP> 1433 && echo "SQL reachable"          # if azure-sql enabled
KUBECONFIG=~/.kube/aks-lab-config kubectl get nodes       # all Ready
```

On the **Mac Pro**, confirm what the tunnel binds (the forwarders point here):

```bash
sudo lsof -nP -iTCP -sTCP:LISTEN | grep -E ':80|:443|:1433'
tail -f /var/log/lab-publish.log        # socat forwarder daemon log
```

---

## iPad / iOS — access from a tablet

The iPad can reach the lab too, but iOS has no `launchctl`, so it can't run the
self-healing tunnel `LaunchAgent` that `./aks-lab dashboard` installs on a Mac
(see [the dashboard tunnel in `aks-lab`](../aks-lab)). You reproduce the pieces
by hand. There are two cases.

### Control dashboard (`:9997`) — via an SSH app

The control dashboard binds **loopback only** on the Mac Pro (`127.0.0.1:9997`
HTTP + `127.0.0.1:9998` terminal WebSocket) and is never published to the LAN —
its terminal tab is a shell into the host. Reach it with an SSH app that does
**local port forwarding**: [Blink Shell] or [Termius] (Blink survives
backgrounding better).

1. **Mac Pro:** enable **System Settings → General → Sharing → Remote Login**,
   then add the iPad app's SSH public key to `~/.ssh/authorized_keys`. Key-based
   login is required — a password prompt would just hang the tunnel.
2. **iPad:** open a forward of **both** ports to the Mac Pro's loopback:

   ```bash
   ssh -N -L 9997:localhost:9997 -L 9998:localhost:9998 <user>@<LAB_HOST_IP>
   ```

   In Termius this is two Port-Forwarding rules
   (`9997 → localhost:9997` and `9998 → localhost:9998`).
3. **iPad Safari:** browse **`http://localhost:9997`** — *not* the Mac Pro's IP.

That last point matters. The server only accepts `Origin: http://localhost:9997`
(`ALLOWED_ORIGINS` in `dashboard-server.py`) and the terminal JS hardcodes
`ws://localhost:9998`, so reaching it through the forwarded `localhost` is what
makes both the page auth (a `SameSite=Strict` cookie) and the terminal work. iOS
loopback is shared across apps, so Safari sees the port the SSH app forwards.

> **No auto-heal.** Unlike the Mac LaunchAgent, this tunnel won't restart
> itself. iOS suspends backgrounded apps, so keep the SSH app in the foreground
> or in split-view; the tunnel drops when it's suspended and you reconnect by
> hand.

### Published web apps (`*.aks-lab.local`) — via DNS

Grafana and the other ingress-served apps are already on the LAN, so the iPad
only needs to resolve `*.aks-lab.local`. iOS has no `/etc/resolver`, so set DNS
for the Wi-Fi network instead: **Settings → Wi-Fi → (network) ⓘ → Configure DNS
→ Manual**, and add `<LAB_HOST_IP>` as the first server. dnsmasq on the Mac Pro
answers `*.aks-lab.local` and forwards everything else upstream, so general
browsing still works. Then open `http://grafana.aks-lab.local`, etc. Switch DNS
back to **Automatic** when you're done.

[Blink Shell]: https://blink.sh
[Termius]: https://termius.com

---

## Active Directory (`corp.internal`) — stretch

With the SambaAD stack enabled, `publish` makes `corp.internal` *resolve* from
the MacBook (dnsmasq forwards to the VM). Full domain interaction (LDAP/Kerberos)
also needs those AD ports forwarded from `LAB_HOST_IP` to the SambaAD VM — add
`389 636 88 464` to the published port set, or join over the Mac Pro. A full
MacBook domain-join is not yet automated.

---

## Uninstall remote publishing

```bash
sudo launchctl bootout system/com.lab.publish
sudo rm /Library/LaunchDaemons/com.lab.publish.plist /usr/local/bin/lab-publish-forward.sh
```
