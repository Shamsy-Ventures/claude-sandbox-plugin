#!/bin/bash
# Launch Claude Code in Docker sandbox
#
# Usage:
#   ./sandbox.sh              - New session in safe mode
#   ./sandbox.sh full         - New session in full trust mode
#   ./sandbox.sh shell        - Open container shell
#   ./sandbox.sh resume       - Resume: pick container + session interactively (full trust)
#   ./sandbox.sh resume safe  - Resume: pick container + session interactively (safe mode)

MODE=${1:-"safe"}
TRUST_MODE=${2:-"full"}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.sandbox-state.json"

# Derive project name from directory
PROJECT_NAME="$(basename "$SCRIPT_DIR")"

# --- Same-path mounting: sessions carry over between host, sandbox, worktrees ---
# Claude Code keys sessions by absolute cwd (~/.claude/projects/<encoded-cwd>).
# Mounting the main repo at its host path inside the container makes those keys
# identical everywhere, and ~/.claude is already shared — so a session started on
# the host is resumable in any sandbox and vice versa. Worktrees created inside
# the repo are subpaths of it, so they inherit this for free. When launched from
# a worktree, mount the MAIN repo (the worktree's gitdir points into it) but
# start Claude in the worktree.
MAIN_REPO_ROOT="$(readlink -f "$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null || echo "$SCRIPT_DIR/.git")/..")"
export SANDBOX_REPO_ROOT="$MAIN_REPO_ROOT"
export SANDBOX_WORKDIR="$SCRIPT_DIR"
export SANDBOX_CONTAINER_NAME="${PROJECT_NAME}-sandbox"

# Pre-create host dirs that compose mounts, so docker doesn't create them root-owned.
mkdir -p "$HOME/.config/gh" "$HOME/.claude"

# --- Helper: record container signature ---
record_container() {
    local name="$1"
    local id
    id=$(docker inspect --format '{{.Id}}' "$name" 2>/dev/null | head -c 12)
    local image
    image=$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null)
    local created
    created=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Read existing state or start fresh
    local entries="[]"
    if [ -f "$STATE_FILE" ]; then
        entries=$(jq '.containers // []' "$STATE_FILE" 2>/dev/null || echo "[]")
    fi

    # Remove stale entry with same name, then append
    entries=$(echo "$entries" | jq --arg n "$name" '[.[] | select(.name != $n)]')
    local new_entry
    new_entry=$(jq -n \
        --arg name "$name" \
        --arg id "$id" \
        --arg image "$image" \
        --arg created "$created" \
        '{name: $name, id: $id, image: $image, created_at: $created}')
    entries=$(echo "$entries" | jq --argjson e "$new_entry" '. + [$e]')

    jq -n --argjson c "$entries" '{containers: $c}' > "$STATE_FILE"
    echo "Container recorded in .sandbox-state.json"
}

# --- Helper: pick a container interactively ---
pick_container() {
    local containers=()

    # First, try containers from the state file (known to this project)
    if [ -f "$STATE_FILE" ]; then
        local known_names
        known_names=$(jq -r '.containers[].name' "$STATE_FILE" 2>/dev/null)
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            local status
            status=$(docker ps -a --filter "name=^${name}$" --format '{{.Status}}' 2>/dev/null)
            if [ -n "$status" ]; then
                containers+=("${name}\t${status}")
            fi
        done <<< "$known_names"
    fi

    # Fallback: scan docker for containers matching the project name
    if [ ${#containers[@]} -eq 0 ]; then
        mapfile -t containers < <(docker ps -a --filter "name=${PROJECT_NAME}" --format '{{.Names}}\t{{.Status}}' 2>/dev/null)
    fi

    if [ ${#containers[@]} -eq 0 ]; then
        echo "Error: No containers found. Run './sandbox.sh full' first." >&2
        exit 1
    fi

    if [ ${#containers[@]} -eq 1 ]; then
        SELECTED=$(echo -e "${containers[0]}" | cut -f1)
        echo "Auto-selected container: $SELECTED" >&2
    else
        echo "" >&2
        echo "Available containers:" >&2
        for i in "${!containers[@]}"; do
            local name=$(echo -e "${containers[$i]}" | cut -f1)
            local status=$(echo -e "${containers[$i]}" | cut -f2)
            echo "  $((i+1))) $name  [$status]" >&2
        done
        echo "" >&2
        read -rp "Select container [1-${#containers[@]}]: " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then
            echo "Invalid selection." >&2
            exit 1
        fi
        SELECTED=$(echo -e "${containers[$((choice-1))]}" | cut -f1)
    fi

    echo "$SELECTED"
}

# --- Helper: ensure container is running ---
ensure_running() {
    local container="$1"
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "Starting stopped container: $container"
        docker start "$container"
    fi
}

# --- Helper: update Claude Code to the latest version ---
# Runs as root because the CLI is installed in the root-owned npm global dir.
update_claude() {
    local container="$1"
    echo "Updating Claude Code to the latest version..."
    if ! docker exec -u root "$container" npm install -g @anthropic-ai/claude-code@latest; then
        echo "WARNING: Claude Code update failed (offline?). Continuing with installed version." >&2
    fi
}

# --- Helper: apply permission profile ---
apply_profile() {
    local mode="$1"
    mkdir -p "$SCRIPT_DIR/.claude/profiles"
    if [ "$mode" = "full" ]; then
        cp "$SCRIPT_DIR/.claude/profiles/full-trust.json" "$SCRIPT_DIR/.claude/settings.local.json" 2>/dev/null || true
    else
        cp "$SCRIPT_DIR/.claude/profiles/safe-mode.json" "$SCRIPT_DIR/.claude/settings.local.json" 2>/dev/null || true
    fi
}

# --- Helper: bootstrap gh + git inside the container (idempotent, runs on every entry) ---
# gh auth comes from the mounted ~/.config/gh (or GH_TOKEN); wire it into git so
# push/pull over https works, enable git-lfs, and carry the host's git identity in.
bootstrap_container() {
    local container="$1"
    local git_name git_email
    git_name="$(git config user.name 2>/dev/null || true)"
    git_email="$(git config user.email 2>/dev/null || true)"
    docker exec \
        -e HOST_GIT_NAME="$git_name" \
        -e HOST_GIT_EMAIL="$git_email" \
        "$container" bash -c '
        command -v gh >/dev/null 2>&1 && gh auth setup-git 2>/dev/null
        command -v git-lfs >/dev/null 2>&1 && git lfs install --skip-repo 2>/dev/null
        [ -n "$HOST_GIT_NAME" ]  && git config --global user.name  "$HOST_GIT_NAME"
        [ -n "$HOST_GIT_EMAIL" ] && git config --global user.email "$HOST_GIT_EMAIL"
        if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
            echo "NOTE: gh is installed but not authenticated. Run: gh auth login" >&2
            echo "      (the token persists via the mounted ~/.config/gh, so this is one-time)" >&2
        fi
        true
    ' 2>/dev/null || true
}

# --- Resume mode ---
if [ "$MODE" = "resume" ]; then
    CONTAINER_NAME=$(pick_container)

    if [ "$TRUST_MODE" = "safe" ]; then
        echo "Resuming in safe mode..."
        CLAUDE_CMD="claude --resume"
        apply_profile "safe"
    else
        echo "Resuming in full trust mode..."
        CLAUDE_CMD="claude --dangerously-skip-permissions --resume"
        apply_profile "full"
    fi

    ensure_running "$CONTAINER_NAME"
    update_claude "$CONTAINER_NAME"
    bootstrap_container "$CONTAINER_NAME"
    docker exec -it "$CONTAINER_NAME" $CLAUDE_CMD
    exit 0
fi

# --- Normal modes (full / safe / shell) ---
CONTAINER_NAME="${PROJECT_NAME}-sandbox"

if [ "$MODE" = "full" ]; then
    echo "WARNING: Running in full trust mode - all commands allowed"
    CLAUDE_CMD="claude --dangerously-skip-permissions"
    apply_profile "full"
elif [ "$MODE" = "shell" ]; then
    echo "Opening container shell (run 'claude' to start Claude Code)"
    CLAUDE_CMD="bash"
    apply_profile "safe"
else
    echo "Running in safe mode with restricted permissions"
    CLAUDE_CMD="claude"
    apply_profile "safe"
fi

# Check if container exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    ensure_running "$CONTAINER_NAME"
    update_claude "$CONTAINER_NAME"
    bootstrap_container "$CONTAINER_NAME"
    echo "Attaching to container..."
    docker exec -it "$CONTAINER_NAME" $CLAUDE_CMD
else
    # Container doesn't exist - create it detached, update Claude, then attach
    echo "Creating new container..."

    # The base compose mounts the main repo at its host path. A worktree created
    # OUTSIDE that tree is not covered by that mount, so add a runtime override
    # that also mounts the worktree at its host path. Standard repos and
    # worktrees created INSIDE the repo tree are subpaths of the repo mount and
    # need nothing extra.
    COMPOSE_ARGS=(-f "$SCRIPT_DIR/docker-compose.sandbox.yml")
    OVERRIDE_FILE="$SCRIPT_DIR/.sandbox-worktree.override.yml"
    rm -f "$OVERRIDE_FILE"
    case "$SANDBOX_WORKDIR/" in
        "$SANDBOX_REPO_ROOT/"*) : ;;
        *)
            cat > "$OVERRIDE_FILE" <<YAML
services:
  claude-sandbox:
    volumes:
      - $SANDBOX_WORKDIR:$SANDBOX_WORKDIR
YAML
            COMPOSE_ARGS+=(-f "$OVERRIDE_FILE")
            echo "Worktree outside repo tree — added mount override for $SANDBOX_WORKDIR"
            ;;
    esac

    docker compose "${COMPOSE_ARGS[@]}" build
    docker compose "${COMPOSE_ARGS[@]}" up -d claude-sandbox
    update_claude "$CONTAINER_NAME"
    bootstrap_container "$CONTAINER_NAME"

    # Record the new container's signature
    record_container "$CONTAINER_NAME"

    docker exec -it "$CONTAINER_NAME" $CLAUDE_CMD
fi
