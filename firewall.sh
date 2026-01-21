#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

DOMAINS_FILE="$1"

# Resolve all domains in parallel via DoH (bypasses local DNS interception)
resolve_all_domains() {
    local domains_file="$1"
    grep -vE '^#|^\s*$' "$domains_file" | xargs -P 20 -I {} sh -c '
        curl -s "https://cloudflare-dns.com/dns-query?name={}&type=A" \
            -H "accept: application/dns-json" 2>/dev/null | \
            jq -r ".Answer[]? | select(.type == 1) | .data" 2>/dev/null
    ' | grep -E '^[1-9][0-9]*\.[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/$/\/32/'
}

# Get host network from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")

# Fetch GitHub IP ranges BEFORE any firewall rules
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

# Collect all IPs into a temp file
IP_LIST=$(mktemp)
trap "rm -f $IP_LIST" EXIT

# Add GitHub CIDRs (filter out IPv6 and bogus)
echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | grep -v ':' | grep -v '^0\.' >>"$IP_LIST"

# Resolve all domains in parallel via DoH
DOMAIN_COUNT=$(grep -cvE '^#|^\s*$' "$DOMAINS_FILE" || echo 0)
resolve_all_domains "$DOMAINS_FILE" >>"$IP_LIST"
RESOLVED_IPS=$(grep -c '/32$' "$IP_LIST" || echo 0)
echo "Resolved $DOMAIN_COUNT domains to $RESOLVED_IPS IPs"

# Use aggregate to merge overlapping ranges and deduplicate
ALL_IPS=$(aggregate -q <"$IP_LIST" | tr '\n' ',' | sed 's/,$//')
TOTAL_RANGES=$(echo "$ALL_IPS" | tr ',' '\n' | wc -l)
echo "Loaded $TOTAL_RANGES total IP ranges (including GitHub)"

# Create nftables rules file
NFT_RULES=$(mktemp)
trap "rm -f $IP_LIST $NFT_RULES" EXIT

cat >"$NFT_RULES" <<EOF
table ip cagent
delete table ip cagent
table ip cagent {
    set allowed-domains {
        type ipv4_addr
        flags interval
        elements = { $ALL_IPS }
    }

    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        ip saddr $HOST_NETWORK accept
        udp sport 53 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy drop;
        ct state established,related accept
        oif lo accept
        ip daddr $HOST_NETWORK accept
        udp dport 53 accept
        tcp dport 22 accept
        ip daddr @allowed-domains accept
        log prefix "[cagent BLOCKED] " limit rate 5/second
        reject with icmp type admin-prohibited
    }
}
EOF

# Load rules atomically
if ! nft -f "$NFT_RULES"; then
    echo "ERROR: Failed to load nftables rules"
    exit 1
fi

# Cache for watchdog to use
cp "$NFT_RULES" /var/cache/firewall-rules.nft

echo "Firewall configuration complete"

# Start watchdog unless --no-watchdog flag passed
if [[ "${2:-}" != "--no-watchdog" ]]; then
    (
        while true; do
            if ! nft list chain ip cagent output 2>/dev/null | grep -q "@allowed-domains"; then
                echo "$(date): Tampering detected, restoring..."
                nft -f /var/cache/firewall-rules.nft
            fi
            sleep 0.1
        done
    ) &
    echo "Firewall watchdog started (PID $!)"
fi
