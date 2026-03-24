#!/usr/bin/env bash
set -euo pipefail

# Wait for both interfaces (external attached at start, internal connected after)
for i in $(seq 1 15); do
    [ "$(ls /sys/class/net/ | grep -v lo | wc -l)" -ge 2 ] && break
    sleep 1
done
[ "$(ls /sys/class/net/ | grep -v lo | wc -l)" -ge 2 ] \
    || { echo "ERROR: timed out waiting for second network interface"; exit 1; }

# Identify internal vs external interface
DEFAULT_GW_IF=$(ip route | grep '^default' | awk '{print $5}' | head -1)
INTERNAL_IF=""
for iface in $(ls /sys/class/net/ | grep -v lo); do
    [ "$iface" != "$DEFAULT_GW_IF" ] && INTERNAL_IF="$iface"
done
[ -n "$INTERNAL_IF" ] || { echo "ERROR: could not identify internal interface"; exit 1; }

echo "Interfaces: external=$DEFAULT_GW_IF internal=$INTERNAL_IF"

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Masquerade outbound traffic from agent
nft add table ip membrane
nft add chain ip membrane postrouting \
    '{ type nat hook postrouting priority srcnat; policy accept; }'
nft add rule ip membrane postrouting oifname "$DEFAULT_GW_IF" masquerade

# Signal ready
touch /tmp/handler-ready
echo "Handler ready."

sleep infinity
