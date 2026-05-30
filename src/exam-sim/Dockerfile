FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    ETCDCTL_API=3

RUN apt-get update -qq && apt-get install -y -qq \
    openssh-server \
    curl \
    wget \
    vim \
    nano \
    tmux \
    jq \
    git \
    openssl \
    base64 \
    bash-completion \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    unzip \
    netcat-openbsd \
    dnsutils \
    iputils-ping \
    iproute2 \
    net-tools \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# kubectl + kubeadm (pinned to match lab K8s version)
RUN KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt) && \
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" && \
    curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubeadm" && \
    install -o root -g root -m 0755 kubectl kubeadm /usr/local/bin/ && \
    rm kubectl kubeadm

# helm
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# etcdctl
RUN ETCD_VER=v3.5.13 && \
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -sL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-${ARCH}.tar.gz" \
      | tar xz --strip-components=1 -C /usr/local/bin etcd-${ETCD_VER}-linux-${ARCH}/etcdctl

# crictl
RUN CRICTL_VER=v1.32.0 && \
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -sL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VER}/crictl-${CRICTL_VER}-linux-${ARCH}.tar.gz" \
      | tar xz -C /usr/local/bin

# yq
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -sLo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" && \
    chmod +x /usr/local/bin/yq

# trivy (for CKS supply chain scenarios)
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    TRIVY_VER=$(curl -sL https://api.github.com/repos/aquasecurity/trivy/releases/latest | grep tag_name | cut -d'"' -f4) && \
    curl -sL "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VER}/trivy_${TRIVY_VER#v}_Linux-$(uname -m | sed 's/x86_64/64bit/;s/aarch64/ARM64/').tar.gz" \
      | tar xz -C /usr/local/bin trivy

RUN mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh

COPY sshd_config /etc/ssh/sshd_config
COPY motd        /etc/motd
COPY bashrc      /root/.bashrc
COPY vimrc       /root/.vimrc
COPY tmux.conf   /root/.tmux.conf

RUN ssh-keygen -A

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D", "-e"]
