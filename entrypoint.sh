#!/bin/bash
set -e

bnd=$(grep '^CapBnd:' /proc/self/status | awk '{print $2}')
if (( 16#$bnd & (1 << 12) )); then

    # -------------------------------------------------------------------------
    # Pre-drop phase — CAP_NET_ADMIN is present
    # -------------------------------------------------------------------------

    # Fix DNS
    echo "nameserver 8.8.8.8" >/etc/resolv.conf
    echo "nameserver 8.8.4.4" >>/etc/resolv.conf

    # Fix MTU
    ip link set dev eth0 mtu 1200 2>/dev/null || true

    # Disable IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true

    # Start DNS logging
    DNS_LOG="/var/log/dns-queries.log"
    touch "$DNS_LOG" && chmod 644 "$DNS_LOG"
    tcpdump -i any -ln port 53 2>/dev/null >> "$DNS_LOG" &
    echo "DNS logging started: $DNS_LOG"

    # Run firewall setup (also starts updater loop in background)
    echo "Setting up firewall..."
    /usr/local/bin/firewall.sh /usr/local/etc/domains.txt

    # Drop CAP_NET_ADMIN and re-exec this script — will enter post-drop phase
    exec capsh --drop=cap_net_admin -- -c 'exec /usr/local/bin/entrypoint.sh "$@"' -- "$@"

fi

# -------------------------------------------------------------------------
# Post-drop phase — CAP_NET_ADMIN is absent
# -------------------------------------------------------------------------

echo "CAP_NET_ADMIN successfully dropped"

# Start Docker daemon if running in Sysbox
if [ "$CAGENT_DIND" = "1" ] && command -v dockerd >/dev/null 2>&1; then
    echo "Starting Docker daemon (Sysbox detected)..." >&2
    dockerd --add-runtime=crun=/usr/bin/crun --default-runtime=crun >/var/log/dockerd.log 2>&1 &

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

# Update agent user to match workspace ownership
WORKSPACE_UID=$(stat -c '%u' /workspace)
WORKSPACE_GID=$(stat -c '%g' /workspace)
usermod -u "$WORKSPACE_UID" cagent 2>/dev/null || true
groupmod -g "$WORKSPACE_GID" cagent 2>/dev/null || true

cd /workspace
exec gosu cagent "${@:-bash}"
