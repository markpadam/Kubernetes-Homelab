# Doze — Power Saving for an Idle Lab

The lab is a learning environment: it sits idle most of the time, but an idle
cluster is anything but idle for the hardware. Measured on the Mac Pro with all
components running and nobody using it:

- **~5.4 CPU cores** burned continuously by Colima's QEMU (apiserver/etcd watch
  churn, controller reconcile loops, Prometheus scraping, Falco eBPF, emulators)
- **~0.8 core** for the two identity Lima VMs (SambaAD, corp-client)
- ≈ **60–90 W above idle, 24/7** — in the £150–250/year range at UK rates

Doze eliminates that: after a configurable idle window it **pauses the lab**
(state-preserving) and **puts the Mac to sleep** (~1–3 W). Waking and resuming
takes ~15 minutes end to end.

---

## Quick start

```bash
# on the Mac Pro (one-time)
./aks-lab doze on                 # enable: doze after 2h idle
./aks-lab doze on --hours 4       # …or a longer window
./aks-lab doze on --no-sleep      # …or pause the lab but keep macOS awake
./aks-lab doze status             # agent state, live activity signals, decision log
./aks-lab doze now                # "done for the day" — pause + sleep immediately
./aks-lab doze off                # disable the agent

# from another machine (e.g. the MacBook), when you want the lab back
./aks-lab wake --wait             # Wake-on-LAN + wait until the host answers
ssh markpadam@<mac-pro> "cd ~/Documents/Kubernetes-Homelab && nohup ./aks-lab resume &"
```

Prerequisites (already set on the lab Mac Pro):

```bash
sudo pmset -a womp 1 autorestart 1          # Wake-on-LAN + reboot after power loss
./aks-lab wake --set-mac <MAC>              # run once on the CLIENT machine
```

> **Which MAC?** The one for the interface the Mac Pro actually uses. The lab
> Mac Pro is on **Wi-Fi**, so the Wi-Fi adapter's MAC is stored — not the
> (unplugged) Ethernet port's. `networksetup -listallhardwareports` shows both.

---

## How it works

Three cooperating pieces, all in `scripts/doze-lab.sh` unless noted:

### 1. The idle-detection agent

`doze on` installs a LaunchAgent (`local.aks-lab-doze`) that runs a check every
15 minutes. The lab counts as **active** if *any* of these signals is present:

| Signal | Detected via |
|--------|--------------|
| Interactive SSH session | `who` (ttys entries — the permanent console login doesn't count) |
| Screen Sharing client connected | `pmset -g assertions` (screensharingd) |
| Remote kubectl / web client | established TCP connections to `:8443` / `:9980` from non-loopback |
| Recent lab use (heartbeat) | mtime of `/tmp/aks-lab-last-activity` — touched by **every `./aks-lab` invocation** and **every authenticated dashboard request** |
| Lab operation in flight | running setup/resume/refresh/teardown/feature/publish scripts |

Notably *not* activity: the MacBook's persistent dashboard SSH tunnel (an idle
`ssh -N` holds no tty), and the doze agent's own checks. Every decision is
appended to `/tmp/aks-lab-doze.log`.

### 2. The doze action

Once every signal has been quiet for the idle window:

1. `pause-lab.sh --colima` — scales down Rancher's crash-prone extension API,
   stops port-forwards, Vault, the dashboard, both Lima VMs, the minikube
   cluster, and the Colima VM. All state is preserved on disk.
2. `pmset sleepnow` — but **only if** Wake-on-LAN is enabled (`womp 1`); doze
   refuses to sleep a box that can't be woken remotely.

If the Mac gets woken by stray traffic and nobody actually uses it, the next
15-minute tick finds it idle and puts it straight back to sleep — observed
working overnight (three stray wakes, each re-slept within a minute).

### 3. The wake-assertion model (why the Mac doesn't nap mid-use)

macOS treats a Wake-on-LAN wake as a **DarkWake**: a ~45-second maintenance
window, after which the OS re-enters sleep unless something asserts
`PreventSystemSleep`. Background SSH sessions assert **nothing** — early
testing had the Mac fall back asleep minutes after a wake, mid-`verify`, with
the entire lab running.

The rule that fixes it: **lab running ⇒ Mac pinned awake; lab paused ⇒ Mac free
to sleep.**

- `resume-lab.sh` starts a detached `caffeinate -s` (PID in
  `/tmp/aks-lab-caffeinate.pid`) and holds it for the life of the lab
- `pause-lab.sh` (and therefore doze) kills it, releasing the Mac to sleep
- `wake --wait` grants a **10-minute grace assertion** over SSH after the host
  answers, so the DarkWake window doesn't close before you start `resume`

If you're working on the Mac Pro over SSH *without* the lab running, hold your
own assertion (`caffeinate -s -t 3600`) or the box may sleep under you.

Reassuring side-effect discovered in testing: QEMU suspends and resumes with
the Mac — a *running* lab survives an unexpected sleep completely intact.

---

## Wake-on-LAN on Wi-Fi vs Ethernet

The Mac Pro currently wakes over **Wi-Fi**, which works but is the fragile
path: a sleeping Wi-Fi radio can miss broadcast magic packets, and deep-standby
wakes are often actually delivered by the network's **Bonjour Sleep Proxy**
reacting to connection attempts. `wake --wait` therefore sends packet bursts
(ports 9 + 7), re-sends every ~15 s while waiting, and keeps pinging — the
pings themselves trigger the proxy path.

Observed timings: **5–10 s** from light sleep; **~3 min** from deep standby
(hibernate-image restore). If wake ever becomes unreliable, plugging either of
the Mac Pro's two Ethernet ports in makes WoL bulletproof.

---

## Configuration & files

| Path | What |
|------|------|
| `~/.aks-lab-doze.conf` | `LAB_DOZE_IDLE_HOURS` (default 2), `LAB_DOZE_SLEEP` (1/0) |
| `~/Library/LaunchAgents/local.aks-lab-doze.plist` | the 15-min check agent |
| `/tmp/aks-lab-doze.log` | every check decision + pause/sleep output |
| `/tmp/aks-lab-last-activity` | the activity heartbeat file |
| `/tmp/aks-lab-caffeinate.pid` | the resume-held wake assertion |

## Troubleshooting

- **SSH to the Mac Pro times out** → it's probably dozing. `./aks-lab wake
  --wait` from another machine, then resume.
- **It never dozes** → `./aks-lab doze status` shows which activity signal is
  holding it awake (a forgotten interactive SSH session is the usual culprit).
- **It dozed while I was using it** → your access path wasn't one of the
  signals (e.g. raw `kubectl` from a machine without the published kubeconfig
  port). Touch the heartbeat via any `./aks-lab` command, or raise `--hours`.
- **`doze now` printed "scheduled" but nothing happened** → check the tail of
  `/tmp/aks-lab-doze.log`; the detached doze logs `detached doze starting`
  within a few seconds of the request.
- **The Mac slept mid-resume** → shouldn't happen anymore (resume holds
  `caffeinate -s` from its first seconds); check the assertion with
  `pmset -g assertions | grep PreventSystemSleep`.
