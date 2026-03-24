#!/usr/bin/env bash
# install-macos.sh
# Sets up Colima on macOS, then runs install-linux.sh inside the VM.
# Usage: bash install-macos.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_SCRIPT="$SCRIPT_DIR/install-linux.sh"

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
[[ "$(uname)" == "Darwin" ]] || error "This script is macOS only."
[[ -f "$LINUX_SCRIPT" ]] || error "install-linux.sh not found at $LINUX_SCRIPT"

# -------------------------------------------------------
# Homebrew dependencies
# -------------------------------------------------------
command -v brew &>/dev/null || error "Homebrew not found. Install from https://brew.sh first."

info "Ensuring colima and docker CLI are installed..."
for pkg in colima docker; do
    brew list "$pkg" &>/dev/null && info "  $pkg already installed" || brew install "$pkg"
done

# -------------------------------------------------------
# Colima VM
#
# CPU/memory/disk can be overridden via environment:
#   COLIMA_CPU=6 COLIMA_MEMORY=8 COLIMA_DISK=60 bash install-macos.sh
#
# Disk size can only be increased after creation, never decreased.
# -------------------------------------------------------
COLIMA_CPU="${COLIMA_CPU:-4}"
COLIMA_MEMORY="${COLIMA_MEMORY:-4}"
COLIMA_DISK="${COLIMA_DISK:-40}"

if colima status 2>/dev/null | grep -q "colima is running"; then
    info "Colima is already running — using existing instance."
    warn "  To recreate with different settings: colima stop && colima delete && bash $0"
elif colima list 2>/dev/null | grep -q "^colima"; then
    info "Colima exists but is stopped — starting it..."
    colima start
else
    info "Creating Colima VM (cpu=${COLIMA_CPU}, memory=${COLIMA_MEMORY}GB, disk=${COLIMA_DISK}GB)..."
    colima start \
        --cpu "$COLIMA_CPU" \
        --memory "$COLIMA_MEMORY" \
        --disk "$COLIMA_DISK" \
        --vm-type vz \
        --mount-type virtiofs \
        --arch aarch64
fi

# -------------------------------------------------------
# Run Linux install script inside the VM
# -------------------------------------------------------
info "Copying install-linux.sh into VM and running..."
colima ssh -- bash -s <"$LINUX_SCRIPT"

# -------------------------------------------------------
# Verify from host
# -------------------------------------------------------
echo ""
info "Runtimes visible from host:"
docker info --format '{{json .Runtimes}}' |
    python3 -c "import sys,json; print('\n'.join(f'  {k}' for k in sorted(json.load(sys.stdin))))"

echo ""
info "Done. Run 'membrane' from any workspace to start."
