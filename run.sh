#!/bin/bash
set -euo pipefail

WORKSPACE="$(pwd)"
AGENTIGNORE_FILE=".agentignore"
EXCLUDE_VOLUMES=()

# Create temporary empty file and directory to reuse for all exclusions
EMPTY_FILE="/tmp/.agent-empty-file"
EMPTY_DIR="/tmp/.agent-empty-dir"
touch "$EMPTY_FILE"
chmod 444 "$EMPTY_FILE"
mkdir -p "$EMPTY_DIR"
chmod 555 "$EMPTY_DIR"

# Read patterns from .agentignore if it exists
if [ -f "$AGENTIGNORE_FILE" ]; then
    echo "Processing $AGENTIGNORE_FILE..." >&2

    while IFS= read -r pattern || [ -n "$pattern" ]; do
        # Skip empty lines and comments
        [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue

        # Remove trailing directory marker if present
        pattern="${pattern%/}"

        # Determine if this is a path-based pattern or name-based pattern
        if [[ "$pattern" == *"/"* ]]; then
            # Path-based pattern: use -path
            find_flag="-path"
            find_pattern="./$pattern"
        else
            # Name-based pattern: use -name
            find_flag="-name"
            find_pattern="$pattern"
        fi

        # Find all matching files/directories
        while IFS= read -r -d '' path; do
            rel_path="${path#./}"

            # Skip the .agentignore file itself
            [[ "$rel_path" == "$AGENTIGNORE_FILE" ]] && continue

            if [ -d "$path" ]; then
                EXCLUDE_VOLUMES+=("-v" "$EMPTY_DIR:/workspace/$rel_path:ro")
                echo "Excluding: $rel_path" >&2
            elif [ -f "$path" ]; then
                EXCLUDE_VOLUMES+=("-v" "$EMPTY_FILE:/workspace/$rel_path:ro")
                echo "Excluding: $rel_path" >&2
            fi
        done < <(find . $find_flag "$find_pattern" -print0 2>/dev/null)
    done <"$AGENTIGNORE_FILE"
fi

# Build docker run command
docker run -it --rm \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    -v "$WORKSPACE:/workspace" \
    $([ -d '.git' ] && echo '-v' "$WORKSPACE/.git:/workspace/.git:ro") \
    $([ -f "$AGENTIGNORE_FILE" ] && echo '-v' "$WORKSPACE/$AGENTIGNORE_FILE:/workspace/$AGENTIGNORE_FILE:ro") \
    "${EXCLUDE_VOLUMES[@]}" \
    -v agent-home:/home/agent \
    agent-box "$@"
