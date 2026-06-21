FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    libicu70 \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pipeline tooling (kubectl, helm, buildah, …) — declared in tools.sh so the agent's
# capabilities live in one editable list. Rebuild the agent image after changing it.
COPY tools.sh /usr/local/bin/agent-tools.sh
RUN chmod +x /usr/local/bin/agent-tools.sh && /usr/local/bin/agent-tools.sh

# Rootless buildah defaults: no daemon, no privileges needed.
ENV BUILDAH_ISOLATION=chroot \
    STORAGE_DRIVER=vfs

WORKDIR /azp/

# Agent binary pre-downloaded and copied in — avoids needing internet access inside the build container
COPY vsts-agent-linux-x64-4.273.0.tar.gz ./
RUN tar -xzf vsts-agent-linux-x64-4.273.0.tar.gz \
    && rm vsts-agent-linux-x64-4.273.0.tar.gz \
    && chmod +x ./config.sh ./run.sh

COPY start.sh ./
RUN chmod +x ./start.sh

RUN adduser --disabled-password --gecos "" --uid 1001 agent \
    && chown -R agent:agent /azp

USER agent

ENTRYPOINT ["./start.sh"]
