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

# Get the UID/GID of /workspace (from host mount)
WORKSPACE_UID=$(stat -c '%u' /workspace)
WORKSPACE_GID=$(stat -c '%g' /workspace)

# Update cagent user to match workspace ownership
usermod -u "$WORKSPACE_UID" cagent 2>/dev/null || true
groupmod -g "$WORKSPACE_GID" cagent 2>/dev/null || true

# Configure AFL++ (needs privileged container)
if [ -w /proc/sys/kernel/core_pattern ]; then
    echo core >/proc/sys/kernel/core_pattern
fi
if [ -w /proc/sys/kernel/sched_child_runs_first ]; then
    echo 1 >/proc/sys/kernel/sched_child_runs_first
fi

# Run firewall setup
echo "Setting up firewall..."
/usr/local/bin/firewall.sh /usr/local/etc/domains.txt

# Switch to workspace directory
cd /workspace

# Drop to cagent user and execute command
exec gosu cagent "${@:-bash}"
