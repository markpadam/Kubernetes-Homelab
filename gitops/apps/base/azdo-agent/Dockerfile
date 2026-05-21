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

WORKDIR /azp/

COPY start.sh ./
RUN chmod +x ./start.sh

RUN adduser --disabled-password --gecos "" --uid 1001 agent \
    && chown -R agent:agent /azp

USER agent

ENTRYPOINT ["./start.sh"]
