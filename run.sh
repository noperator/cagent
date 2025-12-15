#!/bin/bash
set -euo pipefail

WORKSPACE="$(pwd)"
CAGENTIGNORE_FILE=".cagentignore"
CAGENTREADONLY_FILE=".cagentreadonly"
EXCLUDE_VOLUMES=()
READONLY_VOLUMES=()
EXCLUDED_DIRS=() # Track excluded directories

# Create temporary empty file and directory to reuse for exclusions (hidden files)
EMPTY_FILE="/tmp/.cagent-empty-file"
EMPTY_DIR="/tmp/.cagent-empty-dir"
touch "$EMPTY_FILE"
chmod 444 "$EMPTY_FILE"
mkdir -p "$EMPTY_DIR"
chmod 555 "$EMPTY_DIR"

# Function to check if a path is inside an excluded directory
is_inside_excluded_dir() {
    local path="$1"
    for excl_dir in "${EXCLUDED_DIRS[@]}"; do
        if [[ "$path" == "$excl_dir"* ]]; then
            return 0 # true, is inside excluded dir
        fi
    done
    return 1 # false, not inside excluded dir
}

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
            [[ "$rel_path" == "$CAGENTIGNORE_FILE" || "$rel_path" == "$CAGENTREADONLY_FILE" ]] && continue

            # Skip if this path is inside an already-excluded directory
            if is_inside_excluded_dir "$rel_path"; then
                continue
            fi

            if [ "$is_readonly" = true ]; then
                # Mount actual host file/dir as read-only
                eval "${volume_array_name}+=(\"-v\" \"$WORKSPACE/$rel_path:/workspace/$rel_path:ro\")"
                echo "  $rel_path" >&2
            else
                # Shadow with empty file/dir
                if [ -d "$path" ]; then
                    eval "${volume_array_name}+=(\"-v\" \"$EMPTY_DIR:/workspace/$rel_path:ro\")"
                    echo "  $rel_path" >&2
                    # Track this excluded directory
                    EXCLUDED_DIRS+=("$rel_path/")
                elif [ -f "$path" ]; then
                    eval "${volume_array_name}+=(\"-v\" \"$EMPTY_FILE:/workspace/$rel_path:ro\")"
                    echo "  $rel_path" >&2
                fi
            fi
        done < <(find . $find_flag "$find_pattern" -print0 2>/dev/null)
    done <"$patterns_source"
}

# Process ignore patterns (hidden completely)
if [ ! -f "$CAGENTIGNORE_FILE" ]; then
    process_patterns "$CAGENTIGNORE_FILE" "EXCLUDE_VOLUMES" true false <<'EOF'
*.bak
*.tmp
EOF
else
    process_patterns "$CAGENTIGNORE_FILE" "EXCLUDE_VOLUMES" false false
fi

# Process read-only patterns (visible but read-only)
if [ ! -f "$CAGENTREADONLY_FILE" ]; then
    process_patterns "$CAGENTREADONLY_FILE" "READONLY_VOLUMES" true true <<'EOF'
.git
.env
notes.txt
EOF
else
    process_patterns "$CAGENTREADONLY_FILE" "READONLY_VOLUMES" false true
fi

# Create cagent home directory if it doesn't exist
CAGENT_HOME="${HOME}/.cagent-home"
mkdir -p "$CAGENT_HOME"

# Check for KVM support and set up device + resource limits
KVM_DEVICE=""
RESOURCE_LIMITS=""
if [ -e /dev/kvm ]; then
    echo "KVM detected - enabling VM support with resource limits" >&2
    KVM_DEVICE="--device /dev/kvm"
    RESOURCE_LIMITS="--cpus=4 --memory=8g --pids-limit=200"
else
    echo "KVM not available - QEMU will run in emulation mode (slow)" >&2
fi

# Build docker run command
docker run -it --rm \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    ${KVM_DEVICE} \
    ${RESOURCE_LIMITS} \
    -v "$WORKSPACE:/workspace" \
    $([ -f "$CAGENTIGNORE_FILE" ] && echo '-v' "$WORKSPACE/$CAGENTIGNORE_FILE:/workspace/$CAGENTIGNORE_FILE:ro") \
    $([ -f "$CAGENTREADONLY_FILE" ] && echo '-v' "$WORKSPACE/$CAGENTREADONLY_FILE:/workspace/$CAGENTREADONLY_FILE:ro") \
    "${READONLY_VOLUMES[@]}" \
    "${EXCLUDE_VOLUMES[@]}" \
    -v "$CAGENT_HOME:/home/cagent" \
    cagent "$@"
