---
name: init-sandbox
description: Initialize a Docker-based Claude Code sandbox for the current project with permission profiles, container tracking, and session resume support
disable-model-invocation: true
---

# Initialize Claude Sandbox

Create all sandbox infrastructure files for the current project. Derive PROJECT_NAME from the current directory name.

## Files to Create

Create ALL of the following files immediately:

### 1. `Dockerfile.claude-sandbox`

```dockerfile
FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (required for Claude Code)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Create workspace directory
WORKDIR /workspace

# Set up non-root user for safety
RUN useradd -m -s /bin/bash claude && chown -R claude:claude /workspace

# Create .claude directory structure for plugins
RUN mkdir -p /home/claude/.claude/plugins/cache/claude-plugins-official/ralph-loop/latest \
    && mkdir -p /home/claude/.claude/plugins/marketplaces \
    && chown -R claude:claude /home/claude/.claude

USER claude

# Copy plugin configuration
COPY --chown=claude:claude .claude-plugins/ /home/claude/.claude/plugins/
COPY --chown=claude:claude .claude-plugins/settings.json /home/claude/.claude/settings.json

CMD ["bash"]
```

### 2. `docker-compose.sandbox.yml`

First check whether the current directory is a **git worktree**: `.git` is a *file* (containing a `gitdir:` line) rather than a directory. This determines which template to use below.

The resource limits (1.5G memory / 1.5 CPUs) are sized so several sandboxes can run in parallel on a small host without one runaway container taking down the machine. If the host is large and only one sandbox runs at a time, they can be raised.

**Standard repository** (`.git` is a directory, or absent) — replace PROJECT_NAME with the actual current directory name:

```yaml
services:
  claude-sandbox:
    build:
      context: .
      dockerfile: Dockerfile.claude-sandbox
    container_name: PROJECT_NAME-sandbox
    volumes:
      - .:/workspace
      - ~/.claude:/home/claude/.claude
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - CLAUDE_CODE_SKIP_ONBOARDING=1
    working_dir: /workspace
    stdin_open: true
    tty: true
    deploy:
      resources:
        limits:
          memory: 1.5G
          cpus: '1.5'
```

**Git worktree** (`.git` is a file) — a worktree's `.git` file and the main repository's `.git/worktrees/<name>/gitdir` link to each other by **absolute host path**, so mounting the worktree at `/workspace` would break every git command inside the container. Instead, mount both the worktree and the main repository at their identical absolute host paths.

Derive the two paths first:
- WORKTREE_PATH: absolute path of the current directory (`pwd`)
- MAIN_REPO_PATH: the main repository root — run `git rev-parse --git-common-dir` and strip the trailing `/.git`

Replace PROJECT_NAME, WORKTREE_PATH, and MAIN_REPO_PATH:

```yaml
services:
  claude-sandbox:
    build:
      context: .
      dockerfile: Dockerfile.claude-sandbox
    container_name: PROJECT_NAME-sandbox
    volumes:
      - WORKTREE_PATH:WORKTREE_PATH
      - MAIN_REPO_PATH:MAIN_REPO_PATH
      - ~/.claude:/home/claude/.claude
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - CLAUDE_CODE_SKIP_ONBOARDING=1
    working_dir: WORKTREE_PATH
    stdin_open: true
    tty: true
    deploy:
      resources:
        limits:
          memory: 1.5G
          cpus: '1.5'
```

### 3. `sandbox.sh`

Do NOT generate this script from scratch. The canonical copy lives in this skill's base directory at `templates/sandbox.sh`. The script contains bash positional variables (`$0`, `$1`) that slash-command argument substitution blanks out if they are embedded in this markdown file unencoded, so prefer copying the template file directly:

```
cp "<skill-base-directory>/templates/sandbox.sh" ./sandbox.sh
chmod +x sandbox.sh
```

The skill invocation message states the base directory (e.g. "Base directory for this skill: ..."). No placeholder replacement is needed — the script derives PROJECT_NAME from its own directory at runtime via `basename`.

**Fallback for restricted sessions:** If the copy fails — e.g. a sandboxed or headless session blocks reading the plugin cache or running `cp` — recreate the script from the embedded copy below instead of writing your own version. The embedded copy is the exact template with every dollar sign encoded as `@DOLLAR@` (so argument substitution cannot blank it). Restore it by replacing every occurrence of `@DOLLAR@` with a single `$` character and nothing else: either perform the replacement yourself as you Write the file, or Write it verbatim and then run `sed -i 's/@DOLLAR@/$/g' sandbox.sh`. The result must be byte-identical to `templates/sandbox.sh`. Verify no `@DOLLAR@` remains in the written file.

<!-- KEEP IN SYNC with templates/sandbox.sh. Regenerate with: sed 's/\$/@DOLLAR@/g' templates/sandbox.sh -->

```
#!/bin/bash
# Launch Claude Code in Docker sandbox
#
# Usage:
#   ./sandbox.sh              - New session in safe mode
#   ./sandbox.sh full         - New session in full trust mode
#   ./sandbox.sh shell        - Open container shell
#   ./sandbox.sh resume       - Resume: pick container + session interactively (full trust)
#   ./sandbox.sh resume safe  - Resume: pick container + session interactively (safe mode)

MODE=@DOLLAR@{1:-"safe"}
TRUST_MODE=@DOLLAR@{2:-"full"}
SCRIPT_DIR="@DOLLAR@(cd "@DOLLAR@(dirname "@DOLLAR@0")" && pwd)"
STATE_FILE="@DOLLAR@{SCRIPT_DIR}/.sandbox-state.json"

# Derive project name from directory
PROJECT_NAME="@DOLLAR@(basename "@DOLLAR@SCRIPT_DIR")"

# --- Helper: record container signature ---
record_container() {
    local name="@DOLLAR@1"
    local id
    id=@DOLLAR@(docker inspect --format '{{.Id}}' "@DOLLAR@name" 2>/dev/null | head -c 12)
    local image
    image=@DOLLAR@(docker inspect --format '{{.Config.Image}}' "@DOLLAR@name" 2>/dev/null)
    local created
    created=@DOLLAR@(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Read existing state or start fresh
    local entries="[]"
    if [ -f "@DOLLAR@STATE_FILE" ]; then
        entries=@DOLLAR@(jq '.containers // []' "@DOLLAR@STATE_FILE" 2>/dev/null || echo "[]")
    fi

    # Remove stale entry with same name, then append
    entries=@DOLLAR@(echo "@DOLLAR@entries" | jq --arg n "@DOLLAR@name" '[.[] | select(.name != @DOLLAR@n)]')
    local new_entry
    new_entry=@DOLLAR@(jq -n \
        --arg name "@DOLLAR@name" \
        --arg id "@DOLLAR@id" \
        --arg image "@DOLLAR@image" \
        --arg created "@DOLLAR@created" \
        '{name: @DOLLAR@name, id: @DOLLAR@id, image: @DOLLAR@image, created_at: @DOLLAR@created}')
    entries=@DOLLAR@(echo "@DOLLAR@entries" | jq --argjson e "@DOLLAR@new_entry" '. + [@DOLLAR@e]')

    jq -n --argjson c "@DOLLAR@entries" '{containers: @DOLLAR@c}' > "@DOLLAR@STATE_FILE"
    echo "Container recorded in .sandbox-state.json"
}

# --- Helper: pick a container interactively ---
pick_container() {
    local containers=()

    # First, try containers from the state file (known to this project)
    if [ -f "@DOLLAR@STATE_FILE" ]; then
        local known_names
        known_names=@DOLLAR@(jq -r '.containers[].name' "@DOLLAR@STATE_FILE" 2>/dev/null)
        while IFS= read -r name; do
            [ -z "@DOLLAR@name" ] && continue
            local status
            status=@DOLLAR@(docker ps -a --filter "name=^@DOLLAR@{name}@DOLLAR@" --format '{{.Status}}' 2>/dev/null)
            if [ -n "@DOLLAR@status" ]; then
                containers+=("@DOLLAR@{name}\t@DOLLAR@{status}")
            fi
        done <<< "@DOLLAR@known_names"
    fi

    # Fallback: scan docker for containers matching the project name
    if [ @DOLLAR@{#containers[@]} -eq 0 ]; then
        mapfile -t containers < <(docker ps -a --filter "name=@DOLLAR@{PROJECT_NAME}" --format '{{.Names}}\t{{.Status}}' 2>/dev/null)
    fi

    if [ @DOLLAR@{#containers[@]} -eq 0 ]; then
        echo "Error: No containers found. Run './sandbox.sh full' first." >&2
        exit 1
    fi

    if [ @DOLLAR@{#containers[@]} -eq 1 ]; then
        SELECTED=@DOLLAR@(echo -e "@DOLLAR@{containers[0]}" | cut -f1)
        echo "Auto-selected container: @DOLLAR@SELECTED" >&2
    else
        echo "" >&2
        echo "Available containers:" >&2
        for i in "@DOLLAR@{!containers[@]}"; do
            local name=@DOLLAR@(echo -e "@DOLLAR@{containers[@DOLLAR@i]}" | cut -f1)
            local status=@DOLLAR@(echo -e "@DOLLAR@{containers[@DOLLAR@i]}" | cut -f2)
            echo "  @DOLLAR@((i+1))) @DOLLAR@name  [@DOLLAR@status]" >&2
        done
        echo "" >&2
        read -rp "Select container [1-@DOLLAR@{#containers[@]}]: " choice
        if ! [[ "@DOLLAR@choice" =~ ^[0-9]+@DOLLAR@ ]] || [ "@DOLLAR@choice" -lt 1 ] || [ "@DOLLAR@choice" -gt @DOLLAR@{#containers[@]} ]; then
            echo "Invalid selection." >&2
            exit 1
        fi
        SELECTED=@DOLLAR@(echo -e "@DOLLAR@{containers[@DOLLAR@((choice-1))]}" | cut -f1)
    fi

    echo "@DOLLAR@SELECTED"
}

# --- Helper: ensure container is running ---
ensure_running() {
    local container="@DOLLAR@1"
    if ! docker ps --format '{{.Names}}' | grep -q "^@DOLLAR@{container}@DOLLAR@"; then
        echo "Starting stopped container: @DOLLAR@container"
        docker start "@DOLLAR@container"
    fi
}

# --- Helper: update Claude Code to the latest version ---
# Runs as root because the CLI is installed in the root-owned npm global dir.
update_claude() {
    local container="@DOLLAR@1"
    echo "Updating Claude Code to the latest version..."
    if ! docker exec -u root "@DOLLAR@container" npm install -g @anthropic-ai/claude-code@latest; then
        echo "WARNING: Claude Code update failed (offline?). Continuing with installed version." >&2
    fi
}

# --- Helper: apply permission profile ---
apply_profile() {
    local mode="@DOLLAR@1"
    mkdir -p .claude/profiles
    if [ "@DOLLAR@mode" = "full" ]; then
        cp .claude/profiles/full-trust.json .claude/settings.local.json 2>/dev/null || true
    else
        cp .claude/profiles/safe-mode.json .claude/settings.local.json 2>/dev/null || true
    fi
}

# --- Resume mode ---
if [ "@DOLLAR@MODE" = "resume" ]; then
    CONTAINER_NAME=@DOLLAR@(pick_container)

    if [ "@DOLLAR@TRUST_MODE" = "safe" ]; then
        echo "Resuming in safe mode..."
        CLAUDE_CMD="claude --resume"
        apply_profile "safe"
    else
        echo "Resuming in full trust mode..."
        CLAUDE_CMD="claude --dangerously-skip-permissions --resume"
        apply_profile "full"
    fi

    ensure_running "@DOLLAR@CONTAINER_NAME"
    update_claude "@DOLLAR@CONTAINER_NAME"
    docker exec -it "@DOLLAR@CONTAINER_NAME" @DOLLAR@CLAUDE_CMD
    exit 0
fi

# --- Normal modes (full / safe / shell) ---
CONTAINER_NAME="@DOLLAR@{PROJECT_NAME}-sandbox"

if [ "@DOLLAR@MODE" = "full" ]; then
    echo "WARNING: Running in full trust mode - all commands allowed"
    CLAUDE_CMD="claude --dangerously-skip-permissions"
    apply_profile "full"
elif [ "@DOLLAR@MODE" = "shell" ]; then
    echo "Opening container shell (run 'claude' to start Claude Code)"
    CLAUDE_CMD="bash"
    apply_profile "safe"
else
    echo "Running in safe mode with restricted permissions"
    CLAUDE_CMD="claude"
    apply_profile "safe"
fi

# Check if container exists
if docker ps -a --format '{{.Names}}' | grep -q "^@DOLLAR@{CONTAINER_NAME}@DOLLAR@"; then
    ensure_running "@DOLLAR@CONTAINER_NAME"
    update_claude "@DOLLAR@CONTAINER_NAME"
    echo "Attaching to container..."
    docker exec -it "@DOLLAR@CONTAINER_NAME" @DOLLAR@CLAUDE_CMD
else
    # Container doesn't exist - create it detached, update Claude, then attach
    echo "Creating new container..."
    docker compose -f docker-compose.sandbox.yml build
    docker compose -f docker-compose.sandbox.yml up -d claude-sandbox
    update_claude "@DOLLAR@CONTAINER_NAME"

    # Record the new container's signature
    record_container "@DOLLAR@CONTAINER_NAME"

    docker exec -it "@DOLLAR@CONTAINER_NAME" @DOLLAR@CLAUDE_CMD
fi
```

### 4. `.claude/profiles/safe-mode.json`

```json
{
  "permissions": {
    "allow": [
      "Read", "Edit", "Write", "Glob", "Grep",
      "Bash(python:*)", "Bash(pip:*)", "Bash(pytest:*)",
      "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)",
      "Bash(git add:*)", "Bash(git commit:*)",
      "Bash(ls:*)", "Bash(tree:*)", "Bash(mkdir:*)",
      "Bash(npm:*)", "Bash(node:*)",
      "WebSearch", "WebFetch"
    ],
    "deny": ["Bash(rm -rf:*)", "Bash(sudo:*)"]
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### 5. `.claude/profiles/full-trust.json`

```json
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "allow": [],
    "deny": []
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### 6. `.claude-plugins/settings.json`

```json
{
  "enabledPlugins": {
    "ralph-loop@claude-plugins-official": true
  }
}
```

### 7. `.claude-plugins/installed_plugins.json`

```json
{
  "version": 2,
  "plugins": {
    "ralph-loop@claude-plugins-official": [
      {
        "scope": "user",
        "installPath": "/home/claude/.claude/plugins/cache/claude-plugins-official/ralph-loop/latest",
        "version": "latest",
        "installedAt": "2026-01-01T00:00:00.000Z"
      }
    ]
  }
}
```

### 8. `.claude-plugins/config.json`

```json
{"autoUpdate": true}
```

### 9. `.claude-plugins/known_marketplaces.json`

```json
{
  "claude-plugins-official": {
    "url": "https://github.com/anthropics/claude-plugins-official",
    "trusted": true
  }
}
```

### 10. Create `.dockerignore`

```
.env
```

### 11. Append to `.gitignore`

```
# Claude sandbox
.claude/settings.local.json
.sandbox-state.json
.env
```

## After Creation

1. Run: `chmod +x sandbox.sh`
2. Display this summary:

```
Sandbox initialized!

Files created:
  - Dockerfile.claude-sandbox
  - docker-compose.sandbox.yml
  - sandbox.sh
  - .dockerignore
  - .claude/profiles/safe-mode.json
  - .claude/profiles/full-trust.json
  - .claude-plugins/ (plugin config)

To start:
  1. Set ANTHROPIC_API_KEY in your environment
  2. ./sandbox.sh        (safe mode)
     ./sandbox.sh full   (full trust)
     ./sandbox.sh shell  (bash shell)
     ./sandbox.sh resume [full|safe]  (resume container + session)

Container tracking:
  - .sandbox-state.json records container name/ID after first run
  - ./sandbox.sh resume reads this file to find your containers
```
