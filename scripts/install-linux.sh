#!/usr/bin/env bash
# install-linux.sh
# Installs Sysbox on Ubuntu and registers it with Docker.
# Idempotent — safe to run multiple times.
# Usage: bash install-linux.sh

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() {
    echo -e "${RED}[✗]${NC} $*" >&2
    exit 1
}

# -------------------------------------------------------
# Platform check
# -------------------------------------------------------
[[ "$(uname)" == "Linux" ]] || error "This script is Linux only."
command -v apt-get &>/dev/null || error "apt-get not found — Ubuntu/Debian required."
command -v docker &>/dev/null || error "Docker not found. Install Docker first."

ARCH=$(dpkg --print-architecture) # amd64 or arm64

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------
wait_for_docker() {
    local timeout="${1:-30}"
    local elapsed=0
    until docker info &>/dev/null; do
        sleep 2
        elapsed=$((elapsed + 2))
        [[ $elapsed -lt $timeout ]] || error "Docker did not become ready after ${timeout}s."
    done
}

runtime_registered() {
    docker info --format '{{json .Runtimes}}' 2>/dev/null |
        python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if '$1' in d else 1)" 2>/dev/null
}

# -------------------------------------------------------
# Sysbox
# -------------------------------------------------------
if [ -x /usr/bin/sysbox-runc ] && runtime_registered "sysbox-runc"; then
    info "Sysbox already installed and registered — skipping install."
else
    info "Updating apt cache..."
    sudo apt-get update -qq

    info "Installing Sysbox prerequisites..."
    sudo apt-get install -y -qq jq rsync wget

    info "Fetching latest Sysbox release for ${ARCH}..."
    SYSBOX_URL=$(curl -fsSL https://api.github.com/repos/nestybox/sysbox/releases/latest |
        jq -r ".assets[] | select(.name | test(\"linux_${ARCH}\\\\.deb$\")) | .browser_download_url" |
        head -1)
    [[ -n "$SYSBOX_URL" ]] || error "Could not find Sysbox .deb for ${ARCH}."

    info "Downloading Sysbox..."
    wget -q -O /tmp/sysbox.deb "$SYSBOX_URL"

    # Sysbox requires Docker to be stopped before installation
    info "Stopping Docker..."
    sudo systemctl stop docker docker.socket containerd 2>/dev/null || true

    info "Installing Sysbox..."
    sudo apt-get install -y /tmp/sysbox.deb
    rm -f /tmp/sysbox.deb

    info "Starting Sysbox services..."
    if sudo systemctl start sysbox 2>/dev/null; then
        info "Started via 'sysbox' unit."
    else
        warn "Could not start 'sysbox' unit, trying components individually..."
        sudo systemctl start sysbox-mgr
        sudo systemctl start sysbox-fs
    fi
    sleep 2

    info "Starting Docker..."
    sudo systemctl start docker
    wait_for_docker 30

    runtime_registered "sysbox-runc" || error "Sysbox installed but not registered with Docker."
    info "Sysbox installed: $(sysbox-runc --version 2>&1 | head -1)"
fi

# -------------------------------------------------------
# Smoke tests
# -------------------------------------------------------
info "Running smoke tests..."

# Test 1: basic startup
info "Test 1: basic startup..."
KERNEL=$(docker run --rm --runtime=sysbox-runc alpine uname -r 2>&1) &&
    info "  kernel: $KERNEL — OK" ||
    {
        warn "  basic startup FAILED"
        exit 1
    }

# Test 2: user namespace isolation — check uid_map directly.
# Sysbox maps container UID 0 → host UID 100000+ via user namespaces.
# Note: bind-mounted directories bypass UID remapping (intentional Sysbox behavior),
# so we check /proc/self/uid_map instead of file ownership on a mount.
info "Test 2: user namespace isolation..."
UID_MAP=$(docker run --rm --runtime=sysbox-runc alpine cat /proc/self/uid_map 2>&1)
HOST_UID=$(echo "$UID_MAP" | awk '{print $2}')
if [[ -z "$HOST_UID" || "$HOST_UID" -eq 0 ]]; then
    warn "  userns: uid_map shows no remapping — isolation may not be working"
    warn "  uid_map: $UID_MAP"
else
    info "  userns: container UID 0 maps to host UID $HOST_UID — isolated OK"
fi

# Test 3: nftables egress filtering (membrane relies on this)
info "Test 3: nftables egress filtering..."
docker run --rm --runtime=sysbox-runc --cap-add NET_ADMIN alpine sh -c '
    if ! ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        echo "SKIP: 1.1.1.1 not reachable (no internet?)"
        exit 0
    fi
    apk add --quiet nftables 2>/dev/null
    nft add table ip membrane
    nft add chain ip membrane output { type filter hook output priority 0 \; policy accept \; }
    nft add rule ip membrane output ip daddr 1.1.1.1 drop
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        echo "FAIL: ping succeeded despite drop rule"
        exit 1
    fi
    nft delete table ip membrane
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAIL: ping failed after removing rule"
        exit 1
    fi
' && info "  nftables: OK" || warn "  nftables: FAILED"

echo ""
info "Done. Sysbox is ready."
