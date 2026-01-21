FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system tools and firewall requirements
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Basic development tools
    git \
    curl \
    wget \
    ca-certificates \
    build-essential \
    software-properties-common \
    # Firewall tools
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    aggregate \
    tcpdump \
    # GitHub CLI
    gh \
    # Shell utilities
    sudo \
    zsh \
    vim \
    less \
    # Other
    jq \
    ripgrep \
    tree \
    unzip \
    zip \
    rsync \
    cmake \
    gnupg \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Install Docker (for optional Sysbox runtime)
RUN apt-get update && apt-get install -y --no-install-recommends \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

# Install crun (latest release)
RUN CRUN_VER=$(curl -s https://api.github.com/repos/containers/crun/releases/latest | grep '"tag_name"' | cut -d'"' -f4) && \
    curl -L -o /usr/bin/crun "https://github.com/containers/crun/releases/download/${CRUN_VER}/crun-${CRUN_VER}-linux-amd64" && \
    chmod +x /usr/bin/crun

# Install Node
ARG NODE_VERSION=20
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install Python
ARG PYTHON_VERSION=3.13
RUN add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && apt-get install -y \
    python${PYTHON_VERSION} \
    python${PYTHON_VERSION}-venv \
    python${PYTHON_VERSION}-dev \
    python3-pip \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 \
    && rm -rf /var/lib/apt/lists/*

# Install Go
ARG GO_VERSION=1.23.2
RUN wget "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" && \
    tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz" && \
    rm "go${GO_VERSION}.linux-amd64.tar.gz"
ENV PATH="/usr/local/go/bin:${PATH}"

# Create non-root user
ARG USERNAME=agent
RUN useradd -m -s /bin/bash ${USERNAME} && \
    echo "${USERNAME}:${USERNAME}" | chpasswd
# RUN useradd -m -s /bin/bash -G sudo ${USERNAME} && \
#     echo "${USERNAME}:${USERNAME}" | chpasswd

# Add agent to docker group for CLI access
RUN usermod -aG docker ${USERNAME}

# Set up passwordless sudo for apt-get and firewall script only
RUN echo "${USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/firewall.sh" > /etc/sudoers.d/${USERNAME}-firewall && \
    echo "${USERNAME} ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt" > /etc/sudoers.d/${USERNAME}-packages && \
    chmod 0440 /etc/sudoers.d/${USERNAME}-*

# Install coding agents
RUN npm install -g @anthropic-ai/claude-code
RUN npm install -g @openai/codex
RUN npm install -g opencode-ai@latest
RUN npm install -g @charmland/crush

# Switch to non-root user
USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/home/${USERNAME}/.cargo/bin:${PATH}"

# Set up Go path
ENV GOPATH="/home/${USERNAME}/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Copy scripts
USER root
COPY firewall.sh /usr/local/bin/
COPY domains.txt /usr/local/etc/
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/firewall.sh /usr/local/bin/entrypoint.sh

# Set workspace
WORKDIR /workspace

# Default shell
ENV SHELL=/bin/bash

# Preserve terminal titles
ENV CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
