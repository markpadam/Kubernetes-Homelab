#!/bin/bash
set -e

if [ -z "${AZP_URL}" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable"
  exit 1
fi

if [ -z "${AZP_TOKEN_FILE}" ]; then
  if [ -z "${AZP_TOKEN}" ]; then
    echo 1>&2 "error: missing AZP_TOKEN environment variable"
    exit 1
  fi
  AZP_TOKEN_FILE=/azp/.token
  echo -n "${AZP_TOKEN}" > "$AZP_TOKEN_FILE"
fi

unset AZP_TOKEN

if [ -n "${AZP_WORK}" ]; then
  mkdir -p "${AZP_WORK}"
fi

cleanup() {
  if [ -e config.sh ]; then
    ./config.sh remove --unattended --auth PAT --token "$(cat "$AZP_TOKEN_FILE")" || true
  fi
}

export VSO_AGENT_IGNORE=AZP_TOKEN,AZP_TOKEN_FILE

# Download agent only if not already baked into the image
if [ ! -f "./config.sh" ]; then
  echo "Determining matching Azure Pipelines agent..."
  ARCH=$(uname -m)
  if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    PLATFORM="linux-arm64"
  else
    PLATFORM="linux-x64"
  fi

  AZP_AGENT_PACKAGES=$(curl -LsS \
    -u "user:$(cat "$AZP_TOKEN_FILE")" \
    -H 'Accept:application/json;' \
    "${AZP_URL}/_apis/distributedtask/packages/agent?platform=${PLATFORM}&\$top=1")

  AZP_AGENT_PACKAGE_LATEST_URL=$(echo "$AZP_AGENT_PACKAGES" \
    | jq -r '.value | map([.version.major,.version.minor,.version.patch,.downloadUrl]) | sort | .[length-1] | .[3]')

  if [ -z "$AZP_AGENT_PACKAGE_LATEST_URL" ] || [ "$AZP_AGENT_PACKAGE_LATEST_URL" = "null" ]; then
    echo 1>&2 "error: could not determine a matching Azure Pipelines agent"
    echo 1>&2 "check that AZP_URL ('${AZP_URL}') is correct and the PAT is valid"
    exit 1
  fi

  echo "Downloading and extracting agent ($PLATFORM)..."
  curl -LsS "$AZP_AGENT_PACKAGE_LATEST_URL" | tar -xz
else
  echo "Using pre-installed Azure Pipelines agent"
fi

source ./env.sh

# Only deregister on a real pod shutdown (TERM/INT) — NOT when run.sh exits on its
# own. The cluster's egress to dev.azure.com is flaky: Agent.Listener's first
# connection often times out (HTTP 00:01:40), and when it does the listener removes
# itself from the pool and exits. Removing the agent on every such exit (the old
# `trap ... EXIT`) made it flap offline forever. Instead we keep the container alive
# and re-register + re-run the listener until it catches a good window and stays in
# "Listening for Jobs"; once connected, the long-poll tolerates intermittent drops.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

register() {
  for attempt in $(seq 1 30); do
    if ./config.sh --unattended \
      --agent "${AZP_AGENT_NAME:-$(hostname)}" \
      --url "${AZP_URL}" \
      --auth PAT \
      --token "$(cat "$AZP_TOKEN_FILE")" \
      --pool "${AZP_POOL:-Default}" \
      --work "${AZP_WORK:-_work}" \
      --replace \
      --acceptTeeEula; then
      return 0
    fi
    echo "config.sh attempt $attempt failed, retrying in 15s..."
    sleep 15
  done
  echo "config.sh failed 30× — will retry the whole cycle"
  return 1
}

chmod +x ./run.sh

# Supervise: (re)register, then run the listener. If the listener exits (e.g. it
# self-removed after a first-connect timeout), loop and try again. We never exit the
# container on a transient failure, so the pod stays Running and the agent recovers
# without a crashloop or a fresh pod.
while true; do
  register || { sleep 10; continue; }
  echo "Running Azure Pipelines agent..."
  ./run.sh "$@" || true
  echo "listener exited; re-registering and restarting in 10s (agent stays in the deployment)..."
  sleep 10
done
