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
    git-lfs \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (auth comes from the mounted ~/.config/gh or GH_TOKEN)
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (Claude Code requires Node >= 22)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
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

A single template covers both standard repositories and git worktrees. It mounts the repo at its **host absolute path** (not `/workspace`) so Claude Code session keys — `~/.claude/projects/<encoded-cwd>` — are identical on the host, inside the container, and across worktrees; combined with the shared `~/.claude` mount, a session started anywhere is resumable everywhere. `sandbox.sh` computes the paths at launch (worktree-aware, via `git rev-parse --git-common-dir`) and exports `SANDBOX_REPO_ROOT` / `SANDBOX_WORKDIR` / `SANDBOX_CONTAINER_NAME`; the `:-` defaults keep a plain `docker compose` invocation working at `/workspace`.

The resource limits (1.5G memory / 1.5 CPUs) are sized so several sandboxes can run in parallel on a small host without one runaway container taking down the machine. If the host is large and only one sandbox runs at a time, they can be raised.

Replace PROJECT_NAME with the actual current directory name:

```yaml
services:
  claude-sandbox:
    build:
      context: .
      dockerfile: Dockerfile.claude-sandbox
    container_name: ${SANDBOX_CONTAINER_NAME:-PROJECT_NAME-sandbox}
    volumes:
      # Repo mounted at its HOST absolute path so Claude Code session keys match
      # between host, container, and worktrees — a session started anywhere is
      # resumable everywhere. sandbox.sh sets SANDBOX_REPO_ROOT; the default
      # keeps plain `docker compose` invocations working at /workspace.
      - ${SANDBOX_REPO_ROOT:-.}:${SANDBOX_REPO_ROOT:-/workspace}
      - ~/.claude:/home/claude/.claude
      # gh auth (hosts.yml) shared with the host: `gh auth login` once — on the
      # host or in any container — and every sandbox stays authenticated.
      - ~/.config/gh:/home/claude/.config/gh
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - CLAUDE_CODE_SKIP_ONBOARDING=1
      - GH_TOKEN=${GH_TOKEN:-}
    working_dir: ${SANDBOX_WORKDIR:-/workspace}
    stdin_open: true
    tty: true
    deploy:
      resources:
        limits:
          memory: 1.5G
          cpus: '1.5'
```

**Git worktrees.** A worktree's `.git` file and the main repository's `.git/worktrees/<name>/gitdir` link to each other by absolute host path, so the container must see the main repo at that same path. `sandbox.sh` resolves the main repo via `git rev-parse --git-common-dir` and mounts it (as `SANDBOX_REPO_ROOT`) while setting `working_dir` to the worktree (`SANDBOX_WORKDIR`). A worktree created **inside** the repo tree (e.g. `git worktree add .claude/worktrees/feature`) is a subpath of that mount, so it — and its session key — carries over automatically. A worktree created **outside** the repo tree is not covered by the repo mount, so on first launch `sandbox.sh` writes a `.sandbox-worktree.override.yml` compose override that additionally mounts the worktree at its host path. Either way, no separate template is needed.

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

# --- Same-path mounting: sessions carry over between host, sandbox, worktrees ---
# Claude Code keys sessions by absolute cwd (~/.claude/projects/<encoded-cwd>).
# Mounting the main repo at its host path inside the container makes those keys
# identical everywhere, and ~/.claude is already shared — so a session started on
# the host is resumable in any sandbox and vice versa. Worktrees created inside
# the repo are subpaths of it, so they inherit this for free. When launched from
# a worktree, mount the MAIN repo (the worktree's gitdir points into it) but
# start Claude in the worktree.
MAIN_REPO_ROOT="@DOLLAR@(readlink -f "@DOLLAR@(git -C "@DOLLAR@SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null || echo "@DOLLAR@SCRIPT_DIR/.git")/..")"
export SANDBOX_REPO_ROOT="@DOLLAR@MAIN_REPO_ROOT"
export SANDBOX_WORKDIR="@DOLLAR@SCRIPT_DIR"
export SANDBOX_CONTAINER_NAME="@DOLLAR@{PROJECT_NAME}-sandbox"

# Pre-create host dirs that compose mounts, so docker doesn't create them root-owned.
mkdir -p "@DOLLAR@HOME/.config/gh" "@DOLLAR@HOME/.claude"

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
    mkdir -p "@DOLLAR@SCRIPT_DIR/.claude/profiles"
    if [ "@DOLLAR@mode" = "full" ]; then
        cp "@DOLLAR@SCRIPT_DIR/.claude/profiles/full-trust.json" "@DOLLAR@SCRIPT_DIR/.claude/settings.local.json" 2>/dev/null || true
    else
        cp "@DOLLAR@SCRIPT_DIR/.claude/profiles/safe-mode.json" "@DOLLAR@SCRIPT_DIR/.claude/settings.local.json" 2>/dev/null || true
    fi
}

# --- Helper: bootstrap gh + git inside the container (idempotent, runs on every entry) ---
# gh auth comes from the mounted ~/.config/gh (or GH_TOKEN); wire it into git so
# push/pull over https works, enable git-lfs, and carry the host's git identity in.
bootstrap_container() {
    local container="@DOLLAR@1"
    local git_name git_email
    git_name="@DOLLAR@(git config user.name 2>/dev/null || true)"
    git_email="@DOLLAR@(git config user.email 2>/dev/null || true)"
    docker exec \
        -e HOST_GIT_NAME="@DOLLAR@git_name" \
        -e HOST_GIT_EMAIL="@DOLLAR@git_email" \
        "@DOLLAR@container" bash -c '
        command -v gh >/dev/null 2>&1 && gh auth setup-git 2>/dev/null
        command -v git-lfs >/dev/null 2>&1 && git lfs install --skip-repo 2>/dev/null
        [ -n "@DOLLAR@HOST_GIT_NAME" ]  && git config --global user.name  "@DOLLAR@HOST_GIT_NAME"
        [ -n "@DOLLAR@HOST_GIT_EMAIL" ] && git config --global user.email "@DOLLAR@HOST_GIT_EMAIL"
        if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
            echo "NOTE: gh is installed but not authenticated. Run: gh auth login" >&2
            echo "      (the token persists via the mounted ~/.config/gh, so this is one-time)" >&2
        fi
        true
    ' 2>/dev/null || true
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
    bootstrap_container "@DOLLAR@CONTAINER_NAME"
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
    bootstrap_container "@DOLLAR@CONTAINER_NAME"
    echo "Attaching to container..."
    docker exec -it "@DOLLAR@CONTAINER_NAME" @DOLLAR@CLAUDE_CMD
else
    # Container doesn't exist - create it detached, update Claude, then attach
    echo "Creating new container..."

    # The base compose mounts the main repo at its host path. A worktree created
    # OUTSIDE that tree is not covered by that mount, so add a runtime override
    # that also mounts the worktree at its host path. Standard repos and
    # worktrees created INSIDE the repo tree are subpaths of the repo mount and
    # need nothing extra.
    COMPOSE_ARGS=(-f "@DOLLAR@SCRIPT_DIR/docker-compose.sandbox.yml")
    OVERRIDE_FILE="@DOLLAR@SCRIPT_DIR/.sandbox-worktree.override.yml"
    rm -f "@DOLLAR@OVERRIDE_FILE"
    case "@DOLLAR@SANDBOX_WORKDIR/" in
        "@DOLLAR@SANDBOX_REPO_ROOT/"*) : ;;
        *)
            cat > "@DOLLAR@OVERRIDE_FILE" <<YAML
services:
  claude-sandbox:
    volumes:
      - @DOLLAR@SANDBOX_WORKDIR:@DOLLAR@SANDBOX_WORKDIR
YAML
            COMPOSE_ARGS+=(-f "@DOLLAR@OVERRIDE_FILE")
            echo "Worktree outside repo tree — added mount override for @DOLLAR@SANDBOX_WORKDIR"
            ;;
    esac

    docker compose "@DOLLAR@{COMPOSE_ARGS[@]}" build
    docker compose "@DOLLAR@{COMPOSE_ARGS[@]}" up -d claude-sandbox
    update_claude "@DOLLAR@CONTAINER_NAME"
    bootstrap_container "@DOLLAR@CONTAINER_NAME"

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
.sandbox-worktree.override.yml
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
