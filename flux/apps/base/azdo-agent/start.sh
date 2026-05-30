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

echo "Configuring Azure Pipelines agent..."
./config.sh --unattended \
  --agent "${AZP_AGENT_NAME:-$(hostname)}" \
  --url "${AZP_URL}" \
  --auth PAT \
  --token "$(cat "$AZP_TOKEN_FILE")" \
  --pool "${AZP_POOL:-Default}" \
  --work "${AZP_WORK:-_work}" \
  --replace \
  --acceptTeeEula

echo "Running Azure Pipelines agent..."
trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

chmod +x ./run.sh
./run.sh "$@"
