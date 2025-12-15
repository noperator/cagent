# syntax=docker/dockerfile:1

FROM ubuntu:22.04

ENV MYTEST=mytest

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system tools and firewall requirements
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
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

# Install Node
ARG NODE_VERSION=20
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install Python
ARG PYTHON_VERSION=3.13
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    add-apt-repository ppa:deadsnakes/ppa && \
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

# Install security research dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    # Build tools (for exploit validation, crash analysis)
    autoconf \
    automake \
    libtool \
    libtool-bin \
    clang-format \
    # Debuggers
    gdb \
    gdb-multiarch \
    # Binary analysis
    binutils \
    file \
    # rr debugger dependencies
    libcapnp-dev \
    # Playwright browser dependencies
    fonts-liberation \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcairo2 \
    libcups2 \
    libdbus-1-3 \
    libexpat1 \
    libfontconfig1 \
    libgcc1 \
    libgconf-2-4 \
    libgdk-pixbuf2.0-0 \
    libglib2.0-0 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libx11-6 \
    libx11-xcb1 \
    libxcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxss1 \
    libxtst6 \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Install Semgrep (static analysis)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip3 install --no-cache-dir --break-system-packages semgrep

# Install rr debugger (record-replay for crash analysis)
# Only available on x86_64 Linux
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends rr \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    || echo "rr not available on this architecture - skipping"

# Install AFL++ fuzzer
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    afl++ \
    afl++-clang \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    || echo "AFL++ not available - skipping"

# Install CodeQL CLI
ARG CODEQL_VERSION=2.15.5
RUN mkdir -p /opt/codeql \
    && curl -L "https://github.com/github/codeql-cli-binaries/releases/download/v${CODEQL_VERSION}/codeql-linux64.zip" -o /tmp/codeql.zip \
    && unzip /tmp/codeql.zip -d /opt \
    && rm /tmp/codeql.zip \
    && ln -s /opt/codeql/codeql /usr/local/bin/codeql

ENV PATH="/opt/codeql:${PATH}"

# Install QEMU for VM-based exploit testing
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-x86-64 \
    qemu-utils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user
ARG USERNAME=cagent
RUN useradd -m -s /bin/bash ${USERNAME} && \
    echo "${USERNAME}:${USERNAME}" | chpasswd

# Set up passwordless sudo for apt-get and firewall script only
RUN echo "${USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/firewall.sh" > /etc/sudoers.d/${USERNAME}-firewall && \
    echo "${USERNAME} ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt" > /etc/sudoers.d/${USERNAME}-packages && \
    chmod 0440 /etc/sudoers.d/${USERNAME}-*

# Install coding agents
RUN --mount=type=cache,target=/root/.npm \
    npm install -g \
    @anthropic-ai/claude-code \
    @openai/codex \
    opencode-ai@latest \
    @charmland/crush

# Switch to non-root user
USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

ENV PATH="/home/${USERNAME}/.cargo/bin:${PATH}"

# Install various Python dependencies
RUN --mount=type=cache,target=/home/cagent/.cache/pip,uid=1000,gid=1000 \
    pip3 install --no-cache-dir --break-system-packages \
    requests>=2.31.0 \
    litellm>=1.0.0 \
    instructor>=1.0.0 \
    pydantic>=2.9.2 \
    tabulate>=0.9.0 \
    beautifulsoup4>=4.12.0 \
    playwright>=1.40.0

# Install Playwright browsers (large download ~1GB)
RUN --mount=type=cache,target=/home/cagent/.cache/ms-playwright,uid=1000,gid=1000 \
    python3 -m playwright install

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

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
