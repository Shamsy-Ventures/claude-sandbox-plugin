#!/bin/bash
# Launch Claude Code in Docker sandbox
#
# Usage:
#   ./sandbox.sh              - New session in safe mode
#   ./sandbox.sh full         - New session in full trust mode
#   ./sandbox.sh shell        - Open container shell
#   ./sandbox.sh resume       - Resume: pick container + session interactively (full trust)
#   ./sandbox.sh resume safe  - Resume: pick container + session interactively (safe mode)
#
# When a sandbox already exists for this project and you run full/safe/shell in
# an interactive terminal, you get a picker: attach to an existing container
# (showing what's running there + its description) or create a new, named one.
# With no existing container, or when non-interactive, it uses the default
# <project>-sandbox container.

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

# --- Helper: record container signature (with optional user description) ---
record_container() {
    local name="$1"
    local description="$2"
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
        --arg description "$description" \
        '{name: $name, id: $id, image: $image, created_at: $created, description: $description}')
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

# --- Helper: what interactive tool (if any) is running in a container ---
# Inspects the container's process args. Echoes claude / codex / shell / "" .
running_tool() {
    local c="$1"
    docker ps --format '{{.Names}}' | grep -q "^${c}$" || return 0   # not running
    local args
    args=$(docker top "$c" -eo args 2>/dev/null)
    if echo "$args" | grep -qiE 'claude-code|@anthropic-ai/claude|(^|/| )claude( |$)'; then
        echo "claude"
    elif echo "$args" | grep -qiE '(^|/| )codex( |$)|codex'; then
        echo "codex"
    elif echo "$args" | grep -qE '(^|/)(ba)?sh( |$)'; then
        echo "shell"
    fi
}

# --- Helper: best-effort summary of the newest Claude session for this repo ---
# Claude Code stores transcripts under ~/.claude/projects/<encoded-cwd>/*.jsonl.
# The mapping is repo-wide (all containers in a repo share it), so this is shown
# as a labeled guess, not a per-container fact.
session_summary() {
    local base="$HOME/.claude/projects"
    [ -d "$base" ] || return 0
    local dir="" e
    for e in "$(printf '%s' "$SANDBOX_WORKDIR" | sed 's#/#-#g')" \
             "$(printf '%s' "$SANDBOX_WORKDIR" | sed 's#[/.]#-#g')"; do
        [ -d "$base/$e" ] && { dir="$base/$e"; break; }
    done
    [ -n "$dir" ] || return 0
    local f
    f=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
    [ -n "$f" ] || return 0
    local s
    s=$(jq -rs '[.[] | select(.type=="summary") | .summary] | last // empty' "$f" 2>/dev/null)
    if [ -z "$s" ]; then
        s=$(jq -rs 'first(.[] | select(.type=="user") | .message.content
                    | if type=="array" then (map(select(.type=="text").text) | join(" ")) else tostring end) // empty' \
            "$f" 2>/dev/null)
    fi
    [ -n "$s" ] && printf '%s' "$s" | tr '\n' ' ' | cut -c1-60
}

# --- Helper: one-line description of what a container is/does ---
describe_container() {
    local c="$1" desc="$2" repo_summary="$3"
    local tool out
    tool=$(running_tool "$c")
    case "$tool" in
        claude) out="running claude"; [ -n "$repo_summary" ] && out="$out ~\"$repo_summary\"" ;;
        codex)  out="running codex" ;;
        shell)  out="shell open" ;;
        *)      out="idle" ;;
    esac
    [ -n "$desc" ] && out="$out · $desc"
    echo "$out"
}

# --- Helper: interactively attach to an existing sandbox or create a new one ---
# Sets SELECTION to a container name, or "new" (user chose to create one), or
# "none" (no existing containers for this project — caller creates the default).
select_or_create() {
    local names=() statuses=() descs=()
    local seen=" " n st d
    while IFS= read -r n; do
        [ -z "$n" ] && continue
        case "$seen" in *" $n "*) continue ;; esac
        st=$(docker ps -a --filter "name=^${n}$" --format '{{.Status}}' 2>/dev/null)
        [ -z "$st" ] && continue
        seen="$seen$n "
        d=""
        [ -f "$STATE_FILE" ] && d=$(jq -r --arg n "$n" '.containers[]? | select(.name==$n) | .description // empty' "$STATE_FILE" 2>/dev/null)
        names+=("$n"); statuses+=("$st"); descs+=("$d")
    done < <( { [ -f "$STATE_FILE" ] && jq -r '.containers[]?.name' "$STATE_FILE" 2>/dev/null
                docker ps -a --filter "name=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null; } )

    if [ ${#names[@]} -eq 0 ]; then
        SELECTION="none"
        return
    fi

    local repo_summary i info
    repo_summary=$(session_summary)
    echo "" >&2
    echo "Sandboxes for ${PROJECT_NAME}:" >&2
    for i in "${!names[@]}"; do
        info=$(describe_container "${names[$i]}" "${descs[$i]}" "$repo_summary")
        printf "  %d) %-26s [%s]  %s\n" "$((i+1))" "${names[$i]}" "${statuses[$i]}" "$info" >&2
    done
    echo "  n) Create a new sandbox" >&2
    echo "" >&2
    read -rp "Attach to [1-${#names[@]}] or 'n' for new: " choice
    if [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
        SELECTION="new"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#names[@]} ]; then
        SELECTION="${names[$((choice-1))]}"
    else
        echo "Invalid selection." >&2
        exit 1
    fi
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

# Choose target container. When at least one sandbox already exists for this
# project and we have an interactive terminal, offer a picker: attach to an
# existing one (with a description of what's running there) or create a new,
# named one. With no existing containers, or when non-interactive (CI/headless),
# fall back to the default single-container behavior so nothing hangs.
CONTAINER_NAME="${PROJECT_NAME}-sandbox"
CREATE_NEW=0
NEW_DESC=""

if [ -t 0 ]; then
    select_or_create
else
    SELECTION="auto"
fi

if [ "$SELECTION" = "new" ]; then
    # Suggest the next free default name, let the user override, and describe it.
    suggest="${PROJECT_NAME}-sandbox"
    if docker ps -a --format '{{.Names}}' | grep -q "^${suggest}$"; then
        k=2
        while docker ps -a --format '{{.Names}}' | grep -q "^${PROJECT_NAME}-sandbox-${k}$"; do k=$((k+1)); done
        suggest="${PROJECT_NAME}-sandbox-${k}"
    fi
    read -rp "Name for new sandbox [${suggest}]: " NEW_NAME
    NEW_NAME="${NEW_NAME:-$suggest}"
    if docker ps -a --format '{{.Names}}' | grep -q "^${NEW_NAME}$"; then
        echo "A container named '$NEW_NAME' already exists — attach to it instead, or pick another name." >&2
        exit 1
    fi
    read -rp "Short description (what's this sandbox for?): " NEW_DESC
    CONTAINER_NAME="$NEW_NAME"
    CREATE_NEW=1
elif [ "$SELECTION" != "none" ] && [ "$SELECTION" != "auto" ]; then
    # User picked an existing container from the menu.
    CONTAINER_NAME="$SELECTION"
    CREATE_NEW=0
else
    # none/auto: default name — attach if it exists, otherwise create it.
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        CREATE_NEW=0
    else
        CREATE_NEW=1
    fi
fi

if [ "$CREATE_NEW" = "0" ]; then
    ensure_running "$CONTAINER_NAME"
    update_claude "$CONTAINER_NAME"
    bootstrap_container "$CONTAINER_NAME"
    echo "Attaching to container: $CONTAINER_NAME"
    docker exec -it "$CONTAINER_NAME" $CLAUDE_CMD
else
    # Create the container detached, update Claude, then attach.
    echo "Creating new container: $CONTAINER_NAME"
    export SANDBOX_CONTAINER_NAME="$CONTAINER_NAME"

    # Each container is its own compose project so multiple sandboxes can
    # coexist in one repo (compose otherwise treats the service as a singleton).
    PROJ="$(printf '%s' "$CONTAINER_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//')"
    [ -z "$PROJ" ] && PROJ="sandbox"

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

    docker compose -p "$PROJ" "${COMPOSE_ARGS[@]}" build
    docker compose -p "$PROJ" "${COMPOSE_ARGS[@]}" up -d claude-sandbox
    update_claude "$CONTAINER_NAME"
    bootstrap_container "$CONTAINER_NAME"

    # Record the new container's signature (with the user's description)
    record_container "$CONTAINER_NAME" "$NEW_DESC"

    docker exec -it "$CONTAINER_NAME" $CLAUDE_CMD
fi
