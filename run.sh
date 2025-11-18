#!/bin/bash
set -euo pipefail

WORKSPACE="$(pwd)"
AGENTIGNORE_FILE=".agentignore"
AGENTREADONLY_FILE=".agentreadonly"
EXCLUDE_VOLUMES=()
READONLY_VOLUMES=()

# Create temporary empty file and directory to reuse for exclusions (hidden files)
EMPTY_FILE="/tmp/.agent-empty-file"
EMPTY_DIR="/tmp/.agent-empty-dir"
touch "$EMPTY_FILE"
chmod 444 "$EMPTY_FILE"
mkdir -p "$EMPTY_DIR"
chmod 555 "$EMPTY_DIR"

# Function to process patterns and add to volume array
process_patterns() {
    local file=$1
    local volume_array_name=$2
    local use_defaults=$3
    local is_readonly=$4 # true = mount actual files ro, false = shadow with empty

    # Determine patterns source
    if [ -f "$file" ]; then
        echo "Processing $file..." >&2
        patterns_source="$file"
    elif [ "$use_defaults" = true ]; then
        echo "Using default patterns for $file..." >&2
        patterns_source="/dev/stdin"
    else
        return
    fi

    while IFS= read -r pattern || [ -n "$pattern" ]; do
        # Skip empty lines and comments
        [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue

        # Remove trailing directory marker if present
        pattern="${pattern%/}"

        # Determine if this is a path-based pattern or name-based pattern
        if [[ "$pattern" == *"/"* ]]; then
            find_flag="-path"
            find_pattern="./$pattern"
        else
            find_flag="-name"
            find_pattern="$pattern"
        fi

        # Find all matching files/directories
        while IFS= read -r -d '' path; do
            rel_path="${path#./}"

            # Skip the config files themselves
            [[ "$rel_path" == "$AGENTIGNORE_FILE" || "$rel_path" == "$AGENTREADONLY_FILE" ]] && continue

            if [ "$is_readonly" = true ]; then
                # Mount actual host file/dir as read-only
                eval "${volume_array_name}+=(\"-v\" \"$WORKSPACE/$rel_path:/workspace/$rel_path:ro\")"
                echo "  $rel_path" >&2
            else
                # Shadow with empty file/dir
                if [ -d "$path" ]; then
                    eval "${volume_array_name}+=(\"-v\" \"$EMPTY_DIR:/workspace/$rel_path:ro\")"
                    echo "  $rel_path" >&2
                elif [ -f "$path" ]; then
                    eval "${volume_array_name}+=(\"-v\" \"$EMPTY_FILE:/workspace/$rel_path:ro\")"
                    echo "  $rel_path" >&2
                fi
            fi
        done < <(find . $find_flag "$find_pattern" -print0 2>/dev/null)
    done <"$patterns_source"
}

# Process ignore patterns (hidden completely)
if [ ! -f "$AGENTIGNORE_FILE" ]; then
    process_patterns "$AGENTIGNORE_FILE" "EXCLUDE_VOLUMES" true false <<'EOF'
*.bak
*.tmp
EOF
else
    process_patterns "$AGENTIGNORE_FILE" "EXCLUDE_VOLUMES" false false
fi

# Process read-only patterns (visible but read-only)
if [ ! -f "$AGENTREADONLY_FILE" ]; then
    process_patterns "$AGENTREADONLY_FILE" "READONLY_VOLUMES" true true <<'EOF'
.git
.env
notes.txt
EOF
else
    process_patterns "$AGENTREADONLY_FILE" "READONLY_VOLUMES" false true
fi

# Build docker run command
docker run -it --rm \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    -v "$WORKSPACE:/workspace" \
    $([ -f "$AGENTIGNORE_FILE" ] && echo '-v' "$WORKSPACE/$AGENTIGNORE_FILE:/workspace/$AGENTIGNORE_FILE:ro") \
    $([ -f "$AGENTREADONLY_FILE" ] && echo '-v' "$WORKSPACE/$AGENTREADONLY_FILE:/workspace/$AGENTREADONLY_FILE:ro") \
    "${READONLY_VOLUMES[@]}" \
    "${EXCLUDE_VOLUMES[@]}" \
    -v agent-home:/home/agent \
    cagent "$@"
