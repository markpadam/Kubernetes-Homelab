#!/bin/bash
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/local/bin"

PROFILE="${LAB_PROFILE:-aks-lab}"
LOGFILE="/var/log/minikube-tunnel.log"
LAB_USER="markpadam"
LAB_HOME="/Users/markpadam"

# Root needs to point HOME at the lab user so minikube finds its kubeconfig/profile
export HOME="$LAB_HOME"
export MINIKUBE_HOME="$LAB_HOME"

log() { echo "[$(date '+%Y-%m-%d %T')] $*" >> "$LOGFILE"; }

log "minikube-tunnel starting (profile: $PROFILE)"

until su - "$LAB_USER" -c "docker info &>/dev/null"; do
  log "Waiting for Docker daemon..."
  sleep 10
done
log "Docker ready"

until su - "$LAB_USER" -c "minikube status -p $PROFILE 2>/dev/null" | grep -q "Running"; do
  log "Waiting for minikube cluster '$PROFILE'..."
  sleep 15
done
log "Cluster ready — starting tunnel"

exec /usr/local/bin/minikube tunnel -p "$PROFILE"
