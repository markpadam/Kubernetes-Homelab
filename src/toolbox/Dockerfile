FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y -qq \
    openssh-server \
    curl \
    wget \
    dnsutils \
    iputils-ping \
    netcat-openbsd \
    nmap \
    tcpdump \
    net-tools \
    iproute2 \
    traceroute \
    vim \
    jq \
    git \
    python3 \
    python3-pip \
    htop \
    unzip \
    ca-certificates \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

RUN KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt) && \
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm kubectl

RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

RUN mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh

RUN apt-get update -qq && apt-get install -y -qq bash-completion && rm -rf /var/lib/apt/lists/*

COPY sshd_config /etc/ssh/sshd_config
COPY motd /etc/motd
COPY bashrc /root/.bashrc

RUN ssh-keygen -A

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D", "-e"]
