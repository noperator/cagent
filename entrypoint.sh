#!/bin/bash
set -e

# Fix DNS
echo "nameserver 8.8.8.8" >/etc/resolv.conf
echo "nameserver 8.8.4.4" >>/etc/resolv.conf

# Fix MTU
ip link set dev eth0 mtu 1200 2>/dev/null || true

# Disable IPv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true

# Start Docker daemon if running in Sysbox
if [ "$CAGENT_DIND" = "1" ] && command -v dockerd >/dev/null 2>&1; then
    echo "Starting Docker daemon (Sysbox detected)..." >&2
    dockerd --add-runtime=crun=/usr/bin/crun --default-runtime=crun >/var/log/dockerd.log 2>&1 &

    # Wait for docker socket to become available
    for i in $(seq 1 30); do
        if [ -S /var/run/docker.sock ]; then
            echo "Docker daemon ready" >&2
            break
        fi
        sleep 1
    done

    if [ ! -S /var/run/docker.sock ]; then
        echo "Warning: Docker daemon failed to start" >&2
    fi
fi

# Get the UID/GID of /workspace (from host mount)
WORKSPACE_UID=$(stat -c '%u' /workspace)
WORKSPACE_GID=$(stat -c '%g' /workspace)

# Update agent user to match workspace ownership
usermod -u "$WORKSPACE_UID" agent 2>/dev/null || true
groupmod -g "$WORKSPACE_GID" agent 2>/dev/null || true

# Run firewall setup
echo "Setting up firewall..."
/usr/local/bin/firewall.sh /usr/local/etc/domains.txt

# Switch to workspace directory
cd /workspace

# Drop to agent user and execute command
exec gosu agent "${@:-bash}"
