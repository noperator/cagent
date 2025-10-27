#!/bin/bash
set -e

# Get the UID/GID of /workspace (from host mount)
WORKSPACE_UID=$(stat -c '%u' /workspace)
WORKSPACE_GID=$(stat -c '%g' /workspace)

# Update agent user to match workspace ownership
usermod -u "$WORKSPACE_UID" agent 2>/dev/null || true
groupmod -g "$WORKSPACE_GID" agent 2>/dev/null || true

# Run firewall setup
echo "Setting up firewall..."
/usr/local/bin/init-firewall.sh /usr/local/etc/domains.txt

# Switch to workspace directory
cd /workspace

# Drop to agent user and execute command
exec gosu agent "${@:-bash}"
