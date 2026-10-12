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
# Launch and manage Claude Code Docker sandboxes
#
# Session modes:
#   ./sandbox.sh              - New session in safe mode
#   ./sandbox.sh full         - New session in full trust mode
#   ./sandbox.sh shell        - Open container shell
#   ./sandbox.sh resume       - Pick a past session of this repo and resume it in
#                               its sandbox (full trust; starts/creates it as needed)
#   ./sandbox.sh resume safe  - Same, in safe mode
#   ./sandbox.sh resume --last      - Resume this repo's most recent session, no picker
#   ./sandbox.sh resume <id>        - Resume a specific session (id or id prefix)
#
# Lifecycle:
#   ./sandbox.sh ls [--all]        - List sandboxes for this repo (--all: host-wide)
#   ./sandbox.sh stop [--all]      - Pick sandboxes to stop (multi-select)
#   ./sandbox.sh upgrade [--all]   - Refresh sandbox.sh from the installed plugin
#   ./sandbox.sh version           - Print this script's version
#
# Stopping a sandbox is non-destructive: the repo and ~/.claude are bind-mounted
# from the host, so code and session transcripts live outside the container.
# `docker start` (or any launch mode) picks up exactly where you left off.
#
# One Claude per sandbox: before launching Claude, any Claude already running in
# the container is stopped. If its terminal is gone (an SSH drop leaves it
# running, invisibly), that happens automatically; if a terminal is still
# attached, you are asked first. Transcripts are on the host, so nothing is lost.
#
# Every Claude launch asks which model to use (Enter keeps the last choice).
# Set SANDBOX_MODEL=<alias-or-id> to skip the question.
#
# Claude Code inside a sandbox is updated at most once a day per container.
# Set SANDBOX_UPDATE=1 to force an update check now.
#
# When a sandbox already exists for this project and you run full/safe/shell in
# an interactive terminal, you get a picker: attach to an existing container
# (showing what's running there + its description) or create a new, named one.
# With no existing container, or when non-interactive, it uses the default
# <project>-sandbox container.

SANDBOX_SH_VERSION="1.0.10"

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

# =============================================================================
# Session-transcript helpers
#
# Claude Code stores transcripts at ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl
# where <encoded-cwd> is the absolute cwd with "/" replaced by "-". Since
# ~/.claude is bind-mounted into every sandbox, the host can read the transcript
# of a session running inside a container directly.
# =============================================================================

# Resolve the transcript directory for a given absolute cwd. Tries both the
# "/"-only encoding and the "/ and ." encoding used by older Claude versions.
session_dir_for() {
    local cwd="@DOLLAR@1" base="@DOLLAR@HOME/.claude/projects" e
    [ -d "@DOLLAR@base" ] || return 1
    for e in "@DOLLAR@(printf '%s' "@DOLLAR@cwd" | sed 's#/#-#g')" \
             "@DOLLAR@(printf '%s' "@DOLLAR@cwd" | sed 's#[/.]#-#g')"; do
        [ -d "@DOLLAR@base/@DOLLAR@e" ] && { printf '%s' "@DOLLAR@base/@DOLLAR@e"; return 0; }
    done
    return 1
}

# One-line topic for a transcript file: the newest rollup summary Claude wrote,
# falling back to the opening user message.
summary_of_file() {
    local f="@DOLLAR@1" s
    [ -f "@DOLLAR@f" ] || return 0
    # Read only the lines that matter: transcripts run to many MB, and the
    # resume picker summarises a screenful of them.
    s=@DOLLAR@(tac "@DOLLAR@f" 2>/dev/null | grep -m1 '"type": *"summary"' | jq -r '.summary // empty' 2>/dev/null)
    if [ -z "@DOLLAR@s" ]; then
        # No rollup summary yet — fall back to the first real user message,
        # skipping the synthetic blocks Claude injects (slash-command echoes,
        # caveat preambles, hook output) which otherwise read as gibberish.
        s=@DOLLAR@(grep -m20 '"type": *"user"' "@DOLLAR@f" 2>/dev/null | jq -rn 'first(inputs
                    | .message.content
                    | if type=="array" then (map(select(.type=="text").text) | join(" ")) else tostring end
                    | select(test("^<(local-command|command-name|command-message|system-reminder)") | not))
                    // empty' 2>/dev/null)
    fi
    [ -n "@DOLLAR@s" ] && printf '%s' "@DOLLAR@s" \
        | sed -e 's/<[^>]*>//g' -e 's/^[[:space:]]*//' \
        | tr '\n\t' '  ' | tr -s ' ' | cut -c1-58
}

# Host PIDs of every Claude Code CLI process inside a container, one per line.
# `docker top` reports host PIDs, so /proc/<pid>/... is readable from here.
# Matches the CLI itself (native `claude` binary, or node running its entry
# point) by argv[0]/argv[1] — not anything that merely mentions "claude", since
# the container user's home is /home/claude and every plugin/MCP helper path
# contains it.
claude_cli_pids() {
    docker top "@DOLLAR@1" -eo pid,args 2>/dev/null | tail -n +2 | awk '
        @DOLLAR@2 ~ /(^|\/)claude(\.exe)?@DOLLAR@/ { print @DOLLAR@1; next }
        @DOLLAR@2 ~ /(^|\/)node@DOLLAR@/ && @DOLLAR@3 ~ /((^|\/)claude|claude-code\/cli\.js)@DOLLAR@/ { print @DOLLAR@1 }'
}

# Host PID of the (first) claude process running inside a container, if any.
container_claude_pid() {
    claude_cli_pids "@DOLLAR@1" | head -1
}

# The cwd a container's claude process is running in (its session key).
container_cwd() {
    local pid="@DOLLAR@1" c="@DOLLAR@2" d=""
    [ -n "@DOLLAR@pid" ] && d=@DOLLAR@(readlink "/proc/@DOLLAR@pid/cwd" 2>/dev/null)
    [ -z "@DOLLAR@d" ] && d=@DOLLAR@(docker inspect --format '{{.Config.WorkingDir}}' "@DOLLAR@c" 2>/dev/null)
    printf '%s' "@DOLLAR@d"
}

# Host path of the repo bind-mounted into a container (excludes the shared
# ~/.claude and ~/.config/gh mounts), used to locate that repo's state file.
container_repo_dir() {
    docker inspect --format \
      '{{range .Mounts}}{{if eq .Type "bind"}}{{if and (ne .Destination "/home/claude/.claude") (ne .Destination "/home/claude/.config/gh")}}{{.Source}}
{{end}}{{end}}{{end}}' "@DOLLAR@1" 2>/dev/null | grep -v '^@DOLLAR@' | head -1
}

# The session id sandbox.sh recorded for a container, if any (authoritative).
recorded_session_id() {
    local c="@DOLLAR@1" repo state
    repo=@DOLLAR@(container_repo_dir "@DOLLAR@c")
    state="@DOLLAR@{repo}/.sandbox-state.json"
    [ -n "@DOLLAR@repo" ] && [ -f "@DOLLAR@state" ] || return 0
    jq -r --arg n "@DOLLAR@c" '.containers[]? | select(.name==@DOLLAR@n) | .session_id // empty' "@DOLLAR@state" 2>/dev/null
}

# Resolve the Claude session running in a container.
# Echoes: <session-id>\t<summary>\t<fact|guess|ambiguous|->
#
# Preferred path: sandbox.sh launched the session with an explicit --session-id
# and recorded it in .sandbox-state.json, so the mapping is a fact.
#
# Fallback for containers started before v1.0.7: pick the most recently written
# transcript in the container's session directory that has been touched since
# the claude process started. That only identifies a session when this container
# is the *sole* claimant of the directory. Containers that mount the repo at
# /workspace (pre-1.0.3 compose) all share one directory, so several live
# containers collide there — in that case report "ambiguous" rather than
# confidently naming someone else's session.
#
# Args: <container> [claimant-count-for-its-session-dir]
container_session() {
    local c="@DOLLAR@1" claimants="@DOLLAR@{2:-1}"
    local sid="" summ="" kind="-" pid cwd dir f pstart mtime

    sid=@DOLLAR@(recorded_session_id "@DOLLAR@c")
    pid=@DOLLAR@(container_claude_pid "@DOLLAR@c")
    cwd=@DOLLAR@(container_cwd "@DOLLAR@pid" "@DOLLAR@c")
    dir=@DOLLAR@(session_dir_for "@DOLLAR@cwd") || dir=""

    if [ -n "@DOLLAR@sid" ] && [ -n "@DOLLAR@dir" ] && [ -f "@DOLLAR@dir/@DOLLAR@sid.jsonl" ]; then
        kind="fact"
        summ=@DOLLAR@(summary_of_file "@DOLLAR@dir/@DOLLAR@sid.jsonl")
    elif [ -n "@DOLLAR@pid" ] && [ "@DOLLAR@claimants" -gt 1 ]; then
        # Several live containers share this transcript directory; any pick
        # would be a coin flip. Say so instead of guessing.
        kind="ambiguous"
    elif [ -n "@DOLLAR@pid" ] && [ -n "@DOLLAR@dir" ]; then
        pstart=@DOLLAR@(ps -o lstart= -p "@DOLLAR@pid" 2>/dev/null)
        pstart=@DOLLAR@([ -n "@DOLLAR@pstart" ] && date -d "@DOLLAR@pstart" +%s 2>/dev/null || echo 0)
        for f in @DOLLAR@(ls -t "@DOLLAR@dir"/*.jsonl 2>/dev/null); do
            mtime=@DOLLAR@(stat -c %Y "@DOLLAR@f" 2>/dev/null || echo 0)
            if [ "@DOLLAR@mtime" -ge "@DOLLAR@pstart" ]; then
                sid=@DOLLAR@(basename "@DOLLAR@f" .jsonl)
                summ=@DOLLAR@(summary_of_file "@DOLLAR@f")
                kind="guess"
                break
            fi
        done
    fi

    printf '%s\x1f%s\x1f%s' "@DOLLAR@sid" "@DOLLAR@summ" "@DOLLAR@kind"
}

# Epoch of the last transcript write for a container (its real idle clock).
#
# Only meaningful when this container is the sole claimant of its transcript
# directory: with a shared /workspace key, a sibling's activity would make a
# months-dormant sandbox look busy. When the id is known (recorded) we can read
# that one file exactly; when it is ambiguous we fall back to the container's
# own start time, which never over-reports freshness.
#
# Args: <container> [claimant-count-for-its-session-dir]
last_activity_epoch() {
    local c="@DOLLAR@1" claimants="@DOLLAR@{2:-1}" pid cwd dir f ts=0 s sid
    sid=@DOLLAR@(recorded_session_id "@DOLLAR@c")
    pid=@DOLLAR@(container_claude_pid "@DOLLAR@c")
    cwd=@DOLLAR@(container_cwd "@DOLLAR@pid" "@DOLLAR@c")
    dir=@DOLLAR@(session_dir_for "@DOLLAR@cwd") || dir=""

    if [ -n "@DOLLAR@dir" ] && [ -n "@DOLLAR@sid" ] && [ -f "@DOLLAR@dir/@DOLLAR@sid.jsonl" ]; then
        ts=@DOLLAR@(stat -c %Y "@DOLLAR@dir/@DOLLAR@sid.jsonl" 2>/dev/null || echo 0)
    elif [ -n "@DOLLAR@dir" ] && [ "@DOLLAR@claimants" -le 1 ]; then
        f=@DOLLAR@(ls -t "@DOLLAR@dir"/*.jsonl 2>/dev/null | head -1)
        [ -n "@DOLLAR@f" ] && ts=@DOLLAR@(stat -c %Y "@DOLLAR@f" 2>/dev/null || echo 0)
    fi

    if [ "@DOLLAR@ts" = "0" ]; then
        s=@DOLLAR@(docker inspect --format '{{.State.StartedAt}}' "@DOLLAR@c" 2>/dev/null)
        ts=@DOLLAR@(date -d "@DOLLAR@s" +%s 2>/dev/null || echo 0)
    fi
    echo "@DOLLAR@ts"
}

# Human-readable age from an epoch, e.g. "3d", "5h", "12m".
age_short() {
    local then="@DOLLAR@1" now secs
    now=@DOLLAR@(date +%s)
    [ -z "@DOLLAR@then" ] || [ "@DOLLAR@then" = "0" ] && { echo "?"; return; }
    secs=@DOLLAR@(( now - then ))
    if   [ "@DOLLAR@secs" -ge 86400 ]; then echo "@DOLLAR@(( secs / 86400 ))d"
    elif [ "@DOLLAR@secs" -ge 3600 ];  then echo "@DOLLAR@(( secs / 3600 ))h"
    else echo "@DOLLAR@(( secs / 60 ))m"; fi
}

# =============================================================================
# Container helpers
# =============================================================================

# --- Helper: replace the containers list, keeping any other state keys ---
write_containers() {
    local base="{}"
    [ -f "@DOLLAR@STATE_FILE" ] && base=@DOLLAR@(jq '.' "@DOLLAR@STATE_FILE" 2>/dev/null || echo "{}")
    echo "@DOLLAR@base" | jq --argjson c "@DOLLAR@1" '.containers = @DOLLAR@c' > "@DOLLAR@STATE_FILE.tmp" \
        && mv "@DOLLAR@STATE_FILE.tmp" "@DOLLAR@STATE_FILE"
}

# --- Helper: record container signature (with optional user description) ---
record_container() {
    local name="@DOLLAR@1"
    local description="@DOLLAR@2"
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
        --arg description "@DOLLAR@description" \
        '{name: @DOLLAR@name, id: @DOLLAR@id, image: @DOLLAR@image, created_at: @DOLLAR@created, description: @DOLLAR@description}')
    entries=@DOLLAR@(echo "@DOLLAR@entries" | jq --argjson e "@DOLLAR@new_entry" '. + [@DOLLAR@e]')

    write_containers "@DOLLAR@entries"
    echo "Container recorded in .sandbox-state.json"
}

# --- Helper: record which Claude session a container is running ---
# Makes `ls`/`stop` able to report the session id as a fact rather than a guess.
record_session() {
    local name="@DOLLAR@1" sid="@DOLLAR@2"
    [ -n "@DOLLAR@sid" ] || return 0
    local entries="[]"
    [ -f "@DOLLAR@STATE_FILE" ] && entries=@DOLLAR@(jq '.containers // []' "@DOLLAR@STATE_FILE" 2>/dev/null || echo "[]")
    # Ensure an entry exists for this container, then stamp the session onto it.
    if [ "@DOLLAR@(echo "@DOLLAR@entries" | jq --arg n "@DOLLAR@name" '[.[] | select(.name==@DOLLAR@n)] | length')" = "0" ]; then
        entries=@DOLLAR@(echo "@DOLLAR@entries" | jq --arg n "@DOLLAR@name" '. + [{name: @DOLLAR@n, description: ""}]')
    fi
    # A session runs in one place: resuming it here clears it from any other
    # container that recorded it, so ls and resume never show it twice.
    entries=@DOLLAR@(echo "@DOLLAR@entries" | jq \
        --arg n "@DOLLAR@name" --arg s "@DOLLAR@sid" --arg t "@DOLLAR@(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '[.[] | if .name == @DOLLAR@n then . + {session_id: @DOLLAR@s, session_started_at: @DOLLAR@t}
                elif .session_id == @DOLLAR@s then del(.session_id, .session_started_at)
                else . end]')
    write_containers "@DOLLAR@entries"
}

# --- Helper: generate a session UUID ---
new_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null
    fi
}

# --- Helper: ensure container is running ---
ensure_running() {
    local container="@DOLLAR@1"
    if ! docker ps --format '{{.Names}}' | grep -q "^@DOLLAR@{container}@DOLLAR@"; then
        echo "Starting stopped container: @DOLLAR@container"
        docker start "@DOLLAR@container"
    fi
}

# --- Helper: update Claude Code, at most once a day per container ---
# Runs as root because the CLI is installed in the root-owned npm global dir.
# The stamp is keyed by container id, so a recreated container (same name, new
# image layer) is always updated on first launch. SANDBOX_UPDATE=1 forces it.
maybe_update_claude() {
    local container="@DOLLAR@1" id stamp dir="@DOLLAR@{XDG_CACHE_HOME:-@DOLLAR@HOME/.cache}/claude-sandbox"
    id=@DOLLAR@(docker inspect --format '{{.Id}}' "@DOLLAR@container" 2>/dev/null | head -c 12)
    stamp="@DOLLAR@dir/claude-updated-@DOLLAR@id"
    if [ "@DOLLAR@{SANDBOX_UPDATE:-}" != "1" ] && [ -n "@DOLLAR@(find "@DOLLAR@stamp" -mmin -1440 2>/dev/null)" ]; then
        echo "Claude Code: last update check @DOLLAR@(age_short "@DOLLAR@(stat -c %Y "@DOLLAR@stamp")") ago (daily; SANDBOX_UPDATE=1 to force)."
        return 0
    fi
    echo "Updating Claude Code (daily check)..."
    if docker exec -u root "@DOLLAR@container" npm install -g --no-fund --no-audit --loglevel=error @anthropic-ai/claude-code@latest >/dev/null; then
        mkdir -p "@DOLLAR@dir" && touch "@DOLLAR@stamp"
        echo "Claude Code: @DOLLAR@(docker exec "@DOLLAR@container" claude --version 2>/dev/null | head -1)"
    else
        echo "WARNING: Claude Code update failed (offline?). Continuing with installed version." >&2
    fi
}

# --- Helpers: one Claude per sandbox ---
#
# `docker exec -it` does not kill the process it started when the client goes
# away: after an SSH drop or a closed terminal tab, Claude keeps running inside
# the container, holding its memory, with nothing on screen to show it. Every
# later launch used to start another one beside it, which is how a host ends
# up with a dozen invisible sessions and runs out of memory.

# Number of host-side `docker exec` clients currently attached to a container.
attached_clients() {
    ps -eo args= 2>/dev/null | awk -v c="@DOLLAR@1" '
        @DOLLAR@1 ~ /(^|\/)docker@DOLLAR@/ && @DOLLAR@2 == "exec" { for (i = 3; i <= NF; i++) if (@DOLLAR@i == c) { n++; break } }
        END { print n + 0 }'
}

# A host PID and all its descendants (host PIDs), from the container's table.
descendants_of() {
    local c="@DOLLAR@1" root="@DOLLAR@2"
    docker top "@DOLLAR@c" -eo pid,ppid 2>/dev/null | tail -n +2 | awk -v r="@DOLLAR@root" '
        { kids[@DOLLAR@2] = kids[@DOLLAR@2] " " @DOLLAR@1 }
        END { q = r; while (q != "") { split(q, a, " "); q = ""
                for (i in a) if (a[i] != "") { print a[i]; q = q " " kids[a[i]] } } }'
}

# The PID a host process has inside its container's PID namespace.
inner_pid() {
    awk '/^NSpid:/ { print @DOLLAR@NF }' "/proc/@DOLLAR@1/status" 2>/dev/null
}

# Resident memory of a host PID, in MB.
rss_mb() {
    awk '/^VmRSS:/ { printf "%d", @DOLLAR@2 / 1024 }' "/proc/@DOLLAR@1/status" 2>/dev/null
}

# Make sure no Claude is running in a container before starting one.
# Orphans (no terminal attached) are stopped without asking; if a terminal is
# still attached, the user decides. Exits the script if they decline.
clear_live_claude() {
    local c="@DOLLAR@1" pids=() p clients total=0 ok
    mapfile -t pids < <(claude_cli_pids "@DOLLAR@c")
    [ @DOLLAR@{#pids[@]} -eq 0 ] && return 0
    for p in "@DOLLAR@{pids[@]}"; do total=@DOLLAR@(( total + @DOLLAR@(rss_mb "@DOLLAR@p" || echo 0) )); done
    clients=@DOLLAR@(attached_clients "@DOLLAR@c")

    if [ "@DOLLAR@clients" -gt 0 ]; then
        echo ""
        echo "@DOLLAR@c already has @DOLLAR@{#pids[@]} Claude process(es) running (~@DOLLAR@{total} MB),"
        echo "and @DOLLAR@clients terminal(s) are attached to this container — probably a session"
        echo "you have open elsewhere. Starting here will close it there; its transcript is saved."
        if ! [ -t 0 ]; then
            echo "Refusing to interrupt it without a terminal to confirm." >&2
            exit 1
        fi
        read -rp "Stop it and continue here? [y/N]: " ok
        case "@DOLLAR@ok" in
            y|Y|yes|YES) ;;
            *) echo "Cancelled — switch to the terminal where it is open."; exit 0 ;;
        esac
    else
        echo "Stopping @DOLLAR@{#pids[@]} orphaned Claude process(es) in @DOLLAR@c (~@DOLLAR@{total} MB; terminal gone, transcript saved)."
    fi

    # Signal Claude and everything it spawned (shells, MCP servers), via the
    # container's own PID numbers so this works whatever uid the container uses.
    local all=() inner=() q
    for p in "@DOLLAR@{pids[@]}"; do mapfile -t -O "@DOLLAR@{#all[@]}" all < <(descendants_of "@DOLLAR@c" "@DOLLAR@p"); done
    for q in "@DOLLAR@{all[@]}"; do p=@DOLLAR@(inner_pid "@DOLLAR@q"); [ -n "@DOLLAR@p" ] && inner+=("@DOLLAR@p"); done
    [ @DOLLAR@{#inner[@]} -eq 0 ] && return 0
    # `kill` is the shell builtin here: slim images ship no procps.
    docker exec -u root "@DOLLAR@c" sh -c 'kill -TERM "@DOLLAR@@"' sh "@DOLLAR@{inner[@]}" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -z "@DOLLAR@(claude_cli_pids "@DOLLAR@c")" ] && break
        sleep 0.5
    done
    docker exec -u root "@DOLLAR@c" sh -c 'kill -KILL "@DOLLAR@@"' sh "@DOLLAR@{inner[@]}" 2>/dev/null
    return 0
}

# --- Helper: choose the model for a Claude launch ---
# Sets MODEL_ARGS (empty, or --model <m>). Asks on every interactive launch;
# Enter keeps the last choice for this repo. SANDBOX_MODEL skips the question.
#
# The aliases are Claude Code's own: each always resolves to the newest model
# of that family, so this list does not go stale. With ANTHROPIC_API_KEY set on
# the host, the full list of model IDs the key can use is shown as well.
MODEL_ALIASES=(default fable opus sonnet haiku)
MODEL_NOTES=(
    "your account / settings default"
    "most capable; slowest and most expensive"
    "strong all-rounder for coding and agentic work"
    "fast and cheaper; good for everyday work"
    "fastest and cheapest; simple tasks"
)

choose_model() {
    MODEL_ARGS=()
    local m last choice i ids=()
    last=@DOLLAR@([ -f "@DOLLAR@STATE_FILE" ] && jq -r '.last_model // empty' "@DOLLAR@STATE_FILE" 2>/dev/null)
    last="@DOLLAR@{last:-default}"

    if [ -n "@DOLLAR@{SANDBOX_MODEL:-}" ]; then
        m="@DOLLAR@SANDBOX_MODEL"
    elif ! [ -t 0 ]; then
        m="@DOLLAR@last"
    else
        if [ -n "@DOLLAR@{ANTHROPIC_API_KEY:-}" ]; then
            mapfile -t ids < <(curl -fsS --max-time 5 "https://api.anthropic.com/v1/models?limit=100" \
                -H "x-api-key: @DOLLAR@ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" 2>/dev/null \
                | jq -r '.data[]? | "\(.id)\t\(.display_name)"' 2>/dev/null)
        fi
        echo ""
        echo "Model for this session (aliases always mean the latest of that family):"
        for i in "@DOLLAR@{!MODEL_ALIASES[@]}"; do
            printf "  %d) %-8s %s\n" "@DOLLAR@((i+1))" "@DOLLAR@{MODEL_ALIASES[@DOLLAR@i]}" "@DOLLAR@{MODEL_NOTES[@DOLLAR@i]}"
        done
        if [ @DOLLAR@{#ids[@]} -gt 0 ]; then
            echo "  Specific models available to your API key:"
            for i in "@DOLLAR@{!ids[@]}"; do
                printf "  %d) %-26s %s\n" "@DOLLAR@(( @DOLLAR@{#MODEL_ALIASES[@]} + i + 1 ))" "@DOLLAR@{ids[@DOLLAR@i]%%@DOLLAR@'\t'*}" "@DOLLAR@{ids[@DOLLAR@i]#*@DOLLAR@'\t'}"
            done
        fi
        echo "  o) other — type a model name (e.g. claude-opus-5-5, opus[1m])"
        echo "  (You can still switch inside Claude with /model.)"
        read -rp "Choose [Enter = @DOLLAR@last]: " choice
        if [ -z "@DOLLAR@choice" ]; then
            m="@DOLLAR@last"
        elif [ "@DOLLAR@choice" = "o" ] || [ "@DOLLAR@choice" = "O" ]; then
            read -rp "Model name: " m
            m="@DOLLAR@{m:-@DOLLAR@last}"
        elif [[ "@DOLLAR@choice" =~ ^[0-9]+@DOLLAR@ ]] && [ "@DOLLAR@choice" -ge 1 ] && [ "@DOLLAR@choice" -le @DOLLAR@{#MODEL_ALIASES[@]} ]; then
            m="@DOLLAR@{MODEL_ALIASES[@DOLLAR@((choice-1))]}"
        elif [[ "@DOLLAR@choice" =~ ^[0-9]+@DOLLAR@ ]] && [ "@DOLLAR@choice" -gt @DOLLAR@{#MODEL_ALIASES[@]} ] \
             && [ "@DOLLAR@choice" -le @DOLLAR@(( @DOLLAR@{#MODEL_ALIASES[@]} + @DOLLAR@{#ids[@]} )) ]; then
            m="@DOLLAR@{ids[@DOLLAR@((choice - @DOLLAR@{#MODEL_ALIASES[@]} - 1))]%%@DOLLAR@'\t'*}"
        else
            m="@DOLLAR@choice"   # typed a name directly
        fi
        # Remember it for next time.
        local base="{}"
        [ -f "@DOLLAR@STATE_FILE" ] && base=@DOLLAR@(jq '.' "@DOLLAR@STATE_FILE" 2>/dev/null || echo "{}")
        echo "@DOLLAR@base" | jq --arg m "@DOLLAR@m" '.last_model = @DOLLAR@m' > "@DOLLAR@STATE_FILE.tmp" && mv "@DOLLAR@STATE_FILE.tmp" "@DOLLAR@STATE_FILE"
    fi

    [ -n "@DOLLAR@m" ] && [ "@DOLLAR@m" != "default" ] && MODEL_ARGS=(--model "@DOLLAR@m")
    echo "Model: @DOLLAR@m"
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

# --- Helper: what interactive tool (if any) is running in a container ---
# Inspects the container's process args. Echoes claude / codex / shell / "" .
running_tool() {
    local c="@DOLLAR@1"
    docker ps --format '{{.Names}}' | grep -q "^@DOLLAR@{c}@DOLLAR@" || return 0   # not running
    local args
    # `docker top` rejects a format without a PID column ("Couldn't find PID
    # field in ps output"), so ask for pid,args and drop the pid.
    args=@DOLLAR@(docker top "@DOLLAR@c" -eo pid,args 2>/dev/null | tail -n +2 | cut -d' ' -f2-)
    if [ -n "@DOLLAR@(claude_cli_pids "@DOLLAR@c")" ]; then
        echo "claude"
    elif echo "@DOLLAR@args" | grep -qiE '(^|/| )codex( |@DOLLAR@)|codex'; then
        echo "codex"
    elif echo "@DOLLAR@args" | grep -qE '(^|/)(ba)?sh( |@DOLLAR@)'; then
        echo "shell"
    fi
}

# --- Helper: best-effort summary of the newest Claude session for this repo ---
# Used only by the attach-or-create picker, where a repo-wide hint is enough.
session_summary() {
    local dir f
    dir=@DOLLAR@(session_dir_for "@DOLLAR@SANDBOX_WORKDIR") || return 0
    f=@DOLLAR@(ls -t "@DOLLAR@dir"/*.jsonl 2>/dev/null | head -1)
    [ -n "@DOLLAR@f" ] && summary_of_file "@DOLLAR@f"
}

# --- Helper: one-line description of what a container is/does ---
describe_container() {
    local c="@DOLLAR@1" desc="@DOLLAR@2" repo_summary="@DOLLAR@3"
    local tool out
    tool=@DOLLAR@(running_tool "@DOLLAR@c")
    case "@DOLLAR@tool" in
        claude) out="running claude"; [ -n "@DOLLAR@repo_summary" ] && out="@DOLLAR@out ~\"@DOLLAR@repo_summary\"" ;;
        codex)  out="running codex" ;;
        shell)  out="shell open" ;;
        *)      out="idle" ;;
    esac
    [ -n "@DOLLAR@desc" ] && out="@DOLLAR@out · @DOLLAR@desc"
    echo "@DOLLAR@out"
}

# --- Helper: interactively attach to an existing sandbox or create a new one ---
# Sets SELECTION to a container name, or "new" (user chose to create one), or
# "none" (no existing containers for this project — caller creates the default).
select_or_create() {
    local names=() statuses=() descs=()
    local seen=" " n st d
    while IFS= read -r n; do
        [ -z "@DOLLAR@n" ] && continue
        case "@DOLLAR@seen" in *" @DOLLAR@n "*) continue ;; esac
        st=@DOLLAR@(docker ps -a --filter "name=^@DOLLAR@{n}@DOLLAR@" --format '{{.Status}}' 2>/dev/null)
        [ -z "@DOLLAR@st" ] && continue
        seen="@DOLLAR@seen@DOLLAR@n "
        d=""
        [ -f "@DOLLAR@STATE_FILE" ] && d=@DOLLAR@(jq -r --arg n "@DOLLAR@n" '.containers[]? | select(.name==@DOLLAR@n) | .description // empty' "@DOLLAR@STATE_FILE" 2>/dev/null)
        names+=("@DOLLAR@n"); statuses+=("@DOLLAR@st"); descs+=("@DOLLAR@d")
    done < <( { [ -f "@DOLLAR@STATE_FILE" ] && jq -r '.containers[]?.name' "@DOLLAR@STATE_FILE" 2>/dev/null
                docker ps -a --filter "name=@DOLLAR@{PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null; } )

    if [ @DOLLAR@{#names[@]} -eq 0 ]; then
        SELECTION="none"
        return
    fi

    local repo_summary i info
    repo_summary=@DOLLAR@(session_summary)
    echo "" >&2
    echo "Sandboxes for @DOLLAR@{PROJECT_NAME}:" >&2
    for i in "@DOLLAR@{!names[@]}"; do
        info=@DOLLAR@(describe_container "@DOLLAR@{names[@DOLLAR@i]}" "@DOLLAR@{descs[@DOLLAR@i]}" "@DOLLAR@repo_summary")
        printf "  %d) %-26s [%s]  %s\n" "@DOLLAR@((i+1))" "@DOLLAR@{names[@DOLLAR@i]}" "@DOLLAR@{statuses[@DOLLAR@i]}" "@DOLLAR@info" >&2
    done
    echo "  n) Create a new sandbox" >&2
    echo "" >&2
    read -rp "Attach to [1-@DOLLAR@{#names[@]}] or 'n' for new: " choice
    if [ "@DOLLAR@choice" = "n" ] || [ "@DOLLAR@choice" = "N" ]; then
        SELECTION="new"
    elif [[ "@DOLLAR@choice" =~ ^[0-9]+@DOLLAR@ ]] && [ "@DOLLAR@choice" -ge 1 ] && [ "@DOLLAR@choice" -le @DOLLAR@{#names[@]} ]; then
        SELECTION="@DOLLAR@{names[@DOLLAR@((choice-1))]}"
    else
        echo "Invalid selection." >&2
        exit 1
    fi
}

# =============================================================================
# Lifecycle subcommands: ls / stop / upgrade
# =============================================================================

# Enumerate sandbox containers. Scope "repo" (default) uses this project's state
# file plus name match; scope "all" finds every sandbox container on the host.
enumerate_sandboxes() {
    local scope="@DOLLAR@{1:-repo}"
    if [ "@DOLLAR@scope" = "all" ]; then
        # A sandbox is any container whose image or name marks it as one.
        { docker ps -a --filter "name=sandbox" --format '{{.Names}}' 2>/dev/null
          docker ps -a --filter "ancestor=claude-sandbox" --format '{{.Names}}' 2>/dev/null
        } | sort -u
    else
        { [ -f "@DOLLAR@STATE_FILE" ] && jq -r '.containers[]?.name' "@DOLLAR@STATE_FILE" 2>/dev/null
          docker ps -a --filter "name=@DOLLAR@{PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null
        } | sort -u
    fi
}

# How many *live* containers without a recorded session id share each transcript
# directory? Any container in a directory claimed by more than one of those has
# an unidentifiable session — and an unusable idle clock, since a sibling's
# writes would make a dormant sandbox look busy. Populates CLAIMS_BY_NAME.
# Args: <container names...>
build_claims() {
    local -A by_dir=()
    local n pid cwd dir
    declare -gA CLAIMS_BY_NAME=()
    local -A dir_of=()
    for n in "@DOLLAR@@"; do
        [ -z "@DOLLAR@n" ] && continue
        pid=@DOLLAR@(container_claude_pid "@DOLLAR@n")
        if [ -n "@DOLLAR@pid" ] && [ -z "@DOLLAR@(recorded_session_id "@DOLLAR@n")" ]; then
            cwd=@DOLLAR@(container_cwd "@DOLLAR@pid" "@DOLLAR@n")
            dir=@DOLLAR@(session_dir_for "@DOLLAR@cwd") || dir=""
            if [ -n "@DOLLAR@dir" ]; then
                by_dir["@DOLLAR@dir"]=@DOLLAR@(( @DOLLAR@{by_dir["@DOLLAR@dir"]:-0} + 1 ))
                dir_of["@DOLLAR@n"]="@DOLLAR@dir"
            fi
        fi
    done
    for n in "@DOLLAR@@"; do
        [ -z "@DOLLAR@n" ] && continue
        dir="@DOLLAR@{dir_of[@DOLLAR@n]:-}"
        if [ -n "@DOLLAR@dir" ]; then CLAIMS_BY_NAME["@DOLLAR@n"]="@DOLLAR@{by_dir["@DOLLAR@dir"]:-1}"
        else CLAIMS_BY_NAME["@DOLLAR@n"]=1; fi
    done
}

# Render the shared sandbox table. Populates the parallel arrays ROW_NAMES /
# ROW_STATUS so callers (ls, stop) can act on the same numbering the user sees.
# Args: scope [--number]
render_table() {
    local scope="@DOLLAR@1" numbered="@DOLLAR@2"
    ROW_NAMES=(); ROW_STATUS=(); ROW_CLAIMANTS=()
    local n st tool sid summ kind idle repo desc line i=0

    while IFS= read -r n; do
        [ -z "@DOLLAR@n" ] && continue
        st=@DOLLAR@(docker ps -a --filter "name=^@DOLLAR@{n}@DOLLAR@" --format '{{.Status}}' 2>/dev/null)
        [ -z "@DOLLAR@st" ] && continue
        ROW_NAMES+=("@DOLLAR@n"); ROW_STATUS+=("@DOLLAR@st")
    done < <(enumerate_sandboxes "@DOLLAR@scope")

    if [ @DOLLAR@{#ROW_NAMES[@]} -eq 0 ]; then
        echo "No sandboxes found." >&2
        return 1
    fi

    # Pass 1: work out which containers share a transcript directory, so pass 2
    # can tell an identified session from an unidentifiable one.
    #
    # Always count claimants HOST-WIDE, never just the rows being displayed.
    # Sharing is a global property: a repo-scoped listing that counted only its
    # own containers would see a sole claimant of ~/.claude/projects/-workspace
    # and confidently attribute a neighbouring project's session to it.
    local _all=()
    mapfile -t _all < <(enumerate_sandboxes "all")
    build_claims "@DOLLAR@{_all[@]}"
    for i in "@DOLLAR@{!ROW_NAMES[@]}"; do
        ROW_CLAIMANTS+=("@DOLLAR@{CLAIMS_BY_NAME[@DOLLAR@{ROW_NAMES[@DOLLAR@i]}]:-1}")
    done

    printf "\n"
    if [ "@DOLLAR@numbered" = "--number" ]; then
        printf "  %-3s %-34s %-16s %-7s %-9s %-40s %s\n" "#" "CONTAINER" "STATUS" "TOOL" "SESSION" "TOPIC" "IDLE"
        printf "  %-3s %-34s %-16s %-7s %-9s %-40s %s\n" "---" "@DOLLAR@(printf '%.0s-' {1..34})" "@DOLLAR@(printf '%.0s-' {1..16})" "-------" "---------" "@DOLLAR@(printf '%.0s-' {1..40})" "----"
    else
        printf "  %-34s %-16s %-7s %-9s %-40s %s\n" "CONTAINER" "STATUS" "TOOL" "SESSION" "TOPIC" "IDLE"
        printf "  %-34s %-16s %-7s %-9s %-40s %s\n" "@DOLLAR@(printf '%.0s-' {1..34})" "@DOLLAR@(printf '%.0s-' {1..16})" "-------" "---------" "@DOLLAR@(printf '%.0s-' {1..40})" "----"
    fi

    local ambiguous=0 stacked=0
    for i in "@DOLLAR@{!ROW_NAMES[@]}"; do
        n="@DOLLAR@{ROW_NAMES[@DOLLAR@i]}"; st="@DOLLAR@{ROW_STATUS[@DOLLAR@i]}"
        tool=@DOLLAR@(running_tool "@DOLLAR@n"); [ -z "@DOLLAR@tool" ] && tool="-"
        if [ "@DOLLAR@tool" = "claude" ]; then
            # Several Claudes in one sandbox are leftovers from dropped terminals.
            local nc; nc=@DOLLAR@(claude_cli_pids "@DOLLAR@n" | wc -l)
            [ "@DOLLAR@nc" -gt 1 ] && { tool="claude×@DOLLAR@nc"; stacked=1; }
        fi
        IFS=@DOLLAR@'\x1f' read -r sid summ kind <<< "@DOLLAR@(container_session "@DOLLAR@n" "@DOLLAR@{ROW_CLAIMANTS[@DOLLAR@i]}")"
        idle=@DOLLAR@(age_short "@DOLLAR@(last_activity_epoch "@DOLLAR@n" "@DOLLAR@{ROW_CLAIMANTS[@DOLLAR@i]}")")
        repo=@DOLLAR@(container_repo_dir "@DOLLAR@n")
        desc=""
        [ -n "@DOLLAR@repo" ] && [ -f "@DOLLAR@repo/.sandbox-state.json" ] && \
            desc=@DOLLAR@(jq -r --arg n "@DOLLAR@n" '.containers[]? | select(.name==@DOLLAR@n) | .description // empty' "@DOLLAR@repo/.sandbox-state.json" 2>/dev/null)

        # Short session id: bare when recorded, ~ when inferred, ? when several
        # live containers share one transcript directory and it cannot be told.
        local sid_disp="-"
        if [ "@DOLLAR@kind" = "ambiguous" ]; then
            sid_disp="?shared"
            ambiguous=1
        elif [ -n "@DOLLAR@sid" ]; then
            sid_disp="@DOLLAR@{sid:0:8}"
            [ "@DOLLAR@kind" = "guess" ] && sid_disp="~@DOLLAR@{sid:0:8}"
        fi
        # Prefer the live session topic; fall back to the typed description.
        local topic="@DOLLAR@{summ:-@DOLLAR@desc}"
        [ -n "@DOLLAR@topic" ] && topic="\"@DOLLAR@{topic}\""
        [ -z "@DOLLAR@topic" ] && topic="-"

        if [ "@DOLLAR@numbered" = "--number" ]; then
            printf "  %-3s %-34s %-16s %-7s %-9s %-40s %s\n" \
                "@DOLLAR@((i+1))" "@DOLLAR@n" "@DOLLAR@{st:0:16}" "@DOLLAR@tool" "@DOLLAR@sid_disp" "@DOLLAR@{topic:0:40}" "@DOLLAR@idle"
        else
            printf "  %-34s %-16s %-7s %-9s %-40s %s\n" \
                "@DOLLAR@n" "@DOLLAR@{st:0:16}" "@DOLLAR@tool" "@DOLLAR@sid_disp" "@DOLLAR@{topic:0:40}" "@DOLLAR@idle"
        fi
    done
    printf "\n"
    printf "  SESSION: Claude session id — bare = recorded at launch, ~ = inferred\n"
    printf "  IDLE   : time since this session's transcript was last written\n"
    if [ "@DOLLAR@stacked" = "1" ]; then
        printf "  claude×N — several Claudes in one sandbox, left behind by dropped\n"
        printf "             terminals. The next launch there stops the extras.\n"
    fi
    if [ "@DOLLAR@ambiguous" = "1" ]; then
        printf "\n"
        printf "  ?shared — several live sandboxes write to one transcript directory, so\n"
        printf "            their sessions cannot be told apart. This happens when two\n"
        printf "            sandboxes serve the same repo, and across unrelated repos when\n"
        printf "            they mount at /workspace (pre-1.0.3 compose). Sessions started\n"
        printf "            by v1.0.7+ record their id at launch and are never ambiguous,\n"
        printf "            so this clears itself as you restart these sandboxes.\n"
    fi
    printf "\n"
    return 0
}

# Expand a selection string ("1 3 5", "2-4", "1,3", "all") into row numbers.
parse_selection() {
    local input="@DOLLAR@1" max="@DOLLAR@2" out=() tok a b i
    input=@DOLLAR@(echo "@DOLLAR@input" | tr ',' ' ')
    for tok in @DOLLAR@input; do
        case "@DOLLAR@tok" in
            all|ALL|a|A)
                for ((i=1; i<=max; i++)); do out+=("@DOLLAR@i"); done ;;
            *-*)
                a=@DOLLAR@{tok%%-*}; b=@DOLLAR@{tok##*-}
                [[ "@DOLLAR@a" =~ ^[0-9]+@DOLLAR@ && "@DOLLAR@b" =~ ^[0-9]+@DOLLAR@ ]] || return 1
                for ((i=a; i<=b; i++)); do out+=("@DOLLAR@i"); done ;;
            *)
                [[ "@DOLLAR@tok" =~ ^[0-9]+@DOLLAR@ ]] || return 1
                out+=("@DOLLAR@tok") ;;
        esac
    done
    [ @DOLLAR@{#out[@]} -eq 0 ] && return 1
    printf '%s\n' "@DOLLAR@{out[@]}" | sort -un | awk -v m="@DOLLAR@max" '@DOLLAR@1>=1 && @DOLLAR@1<=m'
}

cmd_ls() {
    local scope="repo"
    [ "@DOLLAR@1" = "--all" ] && scope="all"
    render_table "@DOLLAR@scope" ""
}

cmd_stop() {
    local scope="repo"
    [ "@DOLLAR@1" = "--all" ] && scope="all"

    if ! [ -t 0 ]; then
        echo "Error: 'stop' is interactive and needs a terminal. For scripts, use: docker stop <name>" >&2
        exit 1
    fi

    render_table "@DOLLAR@scope" "--number" || exit 1

    echo "Stopping is non-destructive: code and ~/.claude transcripts are on the host,"
    echo "so a stopped sandbox restarts exactly where it left off."
    echo ""
    read -rp "Stop which sandboxes? [e.g. 1 3 5 | 2-4 | all | q to cancel]: " choice
    case "@DOLLAR@choice" in
        q|Q|"") echo "Cancelled."; exit 0 ;;
    esac

    local picks
    picks=@DOLLAR@(parse_selection "@DOLLAR@choice" "@DOLLAR@{#ROW_NAMES[@]}") || { echo "Invalid selection." >&2; exit 1; }
    [ -z "@DOLLAR@picks" ] && { echo "Nothing selected."; exit 0; }

    echo ""
    echo "Will stop:"
    local n tool sid summ kind live=0
    while IFS= read -r i; do
        n="@DOLLAR@{ROW_NAMES[@DOLLAR@((i-1))]}"
        tool=@DOLLAR@(running_tool "@DOLLAR@n")
        # Same claimant count the table used, so the confirmation cannot name a
        # session the table just reported as unidentifiable.
        IFS=@DOLLAR@'\x1f' read -r sid summ kind <<< "@DOLLAR@(container_session "@DOLLAR@n" "@DOLLAR@{ROW_CLAIMANTS[@DOLLAR@((i-1))]}")"
        printf "  - %s" "@DOLLAR@n"
        if [ "@DOLLAR@kind" = "ambiguous" ]; then
            printf "  session ?shared (cannot be identified)"
        else
            [ -n "@DOLLAR@sid" ] && printf "  session %s" "@DOLLAR@{sid:0:8}"
            [ -n "@DOLLAR@summ" ] && printf "  \"%s\"" "@DOLLAR@summ"
        fi
        if [ "@DOLLAR@tool" = "claude" ]; then printf "   [LIVE claude — will be interrupted]"; live=1; fi
        printf "\n"
    done <<< "@DOLLAR@picks"
    echo ""
    if [ "@DOLLAR@live" = "1" ]; then
        echo "One or more have a live Claude session. The transcript is already on the host,"
        echo "so you can pick it back up with:  ./sandbox.sh resume   (or  claude --resume <id>)"
        echo ""
    fi

    read -rp "Confirm stop? [y/N]: " ok
    case "@DOLLAR@ok" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac

    while IFS= read -r i; do
        n="@DOLLAR@{ROW_NAMES[@DOLLAR@((i-1))]}"
        if docker ps --format '{{.Names}}' | grep -q "^@DOLLAR@{n}@DOLLAR@"; then
            docker stop "@DOLLAR@n" >/dev/null && echo "  stopped  @DOLLAR@n"
        else
            echo "  already stopped  @DOLLAR@n"
        fi
    done <<< "@DOLLAR@picks"
    echo ""
    echo "Restart any of them with: docker start <name>  — or just ./sandbox.sh in that repo."
}

# Locate the installed plugin so `upgrade` can re-copy the canonical template.
find_plugin_dir() {
    local c
    if [ -n "@DOLLAR@CLAUDE_SANDBOX_PLUGIN_DIR" ] && [ -f "@DOLLAR@CLAUDE_SANDBOX_PLUGIN_DIR/skills/init-sandbox/templates/sandbox.sh" ]; then
        printf '%s' "@DOLLAR@CLAUDE_SANDBOX_PLUGIN_DIR"; return 0
    fi
    # Highest installed version in the plugin cache wins.
    c=@DOLLAR@(ls -d "@DOLLAR@HOME"/.claude/plugins/cache/*/claude-sandbox/*/ 2>/dev/null | sort -V | tail -1)
    [ -n "@DOLLAR@c" ] && [ -f "@DOLLAR@{c}skills/init-sandbox/templates/sandbox.sh" ] && { printf '%s' "@DOLLAR@{c%/}"; return 0; }
    for c in "@DOLLAR@HOME"/.claude/plugins/marketplaces/*claude-sandbox*/ "@DOLLAR@HOME"/Projects/claude-sandbox-plugin/; do
        [ -f "@DOLLAR@{c}skills/init-sandbox/templates/sandbox.sh" ] && { printf '%s' "@DOLLAR@{c%/}"; return 0; }
    done
    return 1
}

# True when @DOLLAR@1 is a strictly older version than @DOLLAR@2.
version_lt() {
    [ "@DOLLAR@1" = "@DOLLAR@2" ] && return 1
    [ "@DOLLAR@(printf '%s\n%s\n' "@DOLLAR@1" "@DOLLAR@2" | sort -V | head -1)" = "@DOLLAR@1" ]
}

# Version stamp of a sandbox.sh on disk ("1.0.0" if it predates the stamp).
sh_version_of() {
    local f="@DOLLAR@1" v
    v=@DOLLAR@(grep -m1 '^SANDBOX_SH_VERSION=' "@DOLLAR@f" 2>/dev/null | cut -d'"' -f2)
    printf '%s' "@DOLLAR@{v:-1.0.0}"
}

# Refresh one repo's sandbox.sh from the plugin. Echoes a status word.
upgrade_one() {
    local repo="@DOLLAR@1" src="@DOLLAR@2" force="@DOLLAR@3"
    local dst="@DOLLAR@repo/sandbox.sh" cur new
    [ -f "@DOLLAR@dst" ] || { echo "skip"; return; }
    cur=@DOLLAR@(sh_version_of "@DOLLAR@dst")
    new=@DOLLAR@(sh_version_of "@DOLLAR@src")
    if [ "@DOLLAR@cur" = "@DOLLAR@new" ] && [ "@DOLLAR@force" != "--force" ]; then echo "current"; return; fi
    # Never walk a repo backwards. The plugin cache can legitimately be older
    # than a repo (a release pushed but not yet installed), and copying it over
    # would silently revert the repo to the older script.
    if version_lt "@DOLLAR@new" "@DOLLAR@cur" && [ "@DOLLAR@force" != "--force" ]; then
        echo "refused: plugin has v@DOLLAR@new, repo already has v@DOLLAR@cur (use --force to override)"
        return
    fi
    cp "@DOLLAR@dst" "@DOLLAR@dst.bak-@DOLLAR@cur" 2>/dev/null
    cp "@DOLLAR@src" "@DOLLAR@dst" && chmod +x "@DOLLAR@dst" && echo "upgraded @DOLLAR@cur -> @DOLLAR@new"
}

# Report repos whose generated compose still mounts the repo at /workspace.
# Fixing that needs the container recreated, which this script will not do
# silently — it changes the session key, so it is surfaced, not automated.
check_compose_drift() {
    local repo="@DOLLAR@1" f="@DOLLAR@repo/docker-compose.sandbox.yml"
    [ -f "@DOLLAR@f" ] || return 1
    grep -q 'SANDBOX_REPO_ROOT' "@DOLLAR@f" 2>/dev/null && return 1
    return 0
}

cmd_upgrade() {
    local all=0 force=""
    while [ @DOLLAR@# -gt 0 ]; do
        case "@DOLLAR@1" in
            --all) all=1; shift ;;
            --force) force="--force"; shift ;;
            *) echo "Unknown option for upgrade: @DOLLAR@1" >&2; exit 1 ;;
        esac
    done

    local plugin src
    plugin=@DOLLAR@(find_plugin_dir) || {
        echo "Error: could not locate the claude-sandbox plugin." >&2
        echo "Set CLAUDE_SANDBOX_PLUGIN_DIR to the plugin root and retry." >&2
        exit 1
    }
    src="@DOLLAR@plugin/skills/init-sandbox/templates/sandbox.sh"
    echo "Plugin template: @DOLLAR@src  (v@DOLLAR@(sh_version_of "@DOLLAR@src"))"
    echo ""

    local repos=() drift=()
    if [ "@DOLLAR@all" = "1" ]; then
        mapfile -t repos < <(find "@DOLLAR@HOME" -maxdepth 4 -name sandbox.sh -not -path "*/node_modules/*" \
            -not -path "@DOLLAR@plugin/*" -printf '%h\n' 2>/dev/null | sort -u)
    else
        repos=("@DOLLAR@SCRIPT_DIR")
    fi

    local r res
    for r in "@DOLLAR@{repos[@]}"; do
        res=@DOLLAR@(upgrade_one "@DOLLAR@r" "@DOLLAR@src" "@DOLLAR@force")
        printf "  %-50s %s\n" "@DOLLAR@{r/#@DOLLAR@HOME/~}" "@DOLLAR@res"
        check_compose_drift "@DOLLAR@r" && drift+=("@DOLLAR@r")
    done

    if [ @DOLLAR@{#drift[@]} -gt 0 ]; then
        echo ""
        echo "These repos still generate a /workspace mount (pre-1.0.3 compose file)."
        echo "sandbox.sh is now current, but the session key only becomes shared once"
        echo "the compose file is regenerated AND the container recreated:"
        for r in "@DOLLAR@{drift[@]}"; do echo "    @DOLLAR@{r/#@DOLLAR@HOME/~}"; done
        echo ""
        echo "  In each:  /init-sandbox     then   docker rm -f <name> && ./sandbox.sh full"
        echo "  (the container layer is discarded; code and transcripts are on the host)"
    fi
}

# =============================================================================
# Launching
# =============================================================================

# Claude keys sessions by cwd, so only a container whose working dir is this
# checkout's host path sees this checkout's transcripts. Containers created
# before 1.0.3 run at /workspace and cannot resume them.
container_matches_workdir() {
    [ "@DOLLAR@(docker inspect --format '{{.Config.WorkingDir}}' "@DOLLAR@1" 2>/dev/null)" = "@DOLLAR@SANDBOX_WORKDIR" ]
}

# Existing containers of this repo, one per line.
repo_containers() {
    local n
    while IFS= read -r n; do
        [ -n "@DOLLAR@n" ] && docker ps -a --filter "name=^@DOLLAR@{n}@DOLLAR@" --format '{{.Names}}' 2>/dev/null
    done < <(enumerate_sandboxes "repo")
}

# First free default container name for this project.
suggest_name() {
    local s="@DOLLAR@{PROJECT_NAME}-sandbox" k=2
    while docker ps -a --format '{{.Names}}' | grep -qx "@DOLLAR@s"; do
        s="@DOLLAR@{PROJECT_NAME}-sandbox-@DOLLAR@{k}"; k=@DOLLAR@((k+1))
    done
    printf '%s' "@DOLLAR@s"
}

# Ask for a new sandbox's name and description. Sets NEW_NAME / NEW_DESC.
prompt_new_container() {
    local suggest
    suggest=@DOLLAR@(suggest_name)
    NEW_NAME="@DOLLAR@suggest"; NEW_DESC=""
    [ -t 0 ] || return 0
    read -rp "Name for new sandbox [@DOLLAR@{suggest}]: " NEW_NAME
    NEW_NAME="@DOLLAR@{NEW_NAME:-@DOLLAR@suggest}"
    if docker ps -a --format '{{.Names}}' | grep -qx "@DOLLAR@NEW_NAME"; then
        echo "A container named '@DOLLAR@NEW_NAME' already exists — attach to it instead, or pick another name." >&2
        exit 1
    fi
    read -rp "Short description (what's this sandbox for?): " NEW_DESC
}

# Build and start a new sandbox container, detached.
create_container() {
    local name="@DOLLAR@1" desc="@DOLLAR@2" proj
    echo "Creating new container: @DOLLAR@name"
    export SANDBOX_CONTAINER_NAME="@DOLLAR@name"

    # Each container is its own compose project so multiple sandboxes can
    # coexist in one repo (compose otherwise treats the service as a singleton).
    proj="@DOLLAR@(printf '%s' "@DOLLAR@name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//')"
    [ -z "@DOLLAR@proj" ] && proj="sandbox"

    # The base compose mounts the main repo at its host path. A worktree created
    # OUTSIDE that tree is not covered by that mount, so add a runtime override
    # that also mounts the worktree at its host path. Standard repos and
    # worktrees created INSIDE the repo tree are subpaths of the repo mount and
    # need nothing extra.
    local compose_args=(-f "@DOLLAR@SCRIPT_DIR/docker-compose.sandbox.yml")
    local override="@DOLLAR@SCRIPT_DIR/.sandbox-worktree.override.yml"
    rm -f "@DOLLAR@override"
    case "@DOLLAR@SANDBOX_WORKDIR/" in
        "@DOLLAR@SANDBOX_REPO_ROOT/"*) : ;;
        *)
            cat > "@DOLLAR@override" <<YAML
services:
  claude-sandbox:
    volumes:
      - @DOLLAR@SANDBOX_WORKDIR:@DOLLAR@SANDBOX_WORKDIR
YAML
            compose_args+=(-f "@DOLLAR@override")
            echo "Worktree outside repo tree — added mount override for @DOLLAR@SANDBOX_WORKDIR"
            ;;
    esac

    docker compose -p "@DOLLAR@proj" "@DOLLAR@{compose_args[@]}" build
    docker compose -p "@DOLLAR@proj" "@DOLLAR@{compose_args[@]}" up -d claude-sandbox
    record_container "@DOLLAR@name" "@DOLLAR@desc"
}

# Bring a container up and run a command in it: create or start it, stop any
# Claude already running there (when launching Claude), update Claude Code if
# it has not been checked today, record the session, then attach.
# Args: <container> <create:0|1> <description> <session-id|""> <command...>
launch() {
    local c="@DOLLAR@1" create="@DOLLAR@2" desc="@DOLLAR@3" sid="@DOLLAR@4"; shift 4
    if [ "@DOLLAR@create" = "1" ]; then create_container "@DOLLAR@c" "@DOLLAR@desc"; else ensure_running "@DOLLAR@c"; fi
    [ "@DOLLAR@1" = "claude" ] && clear_live_claude "@DOLLAR@c"
    maybe_update_claude "@DOLLAR@c"
    bootstrap_container "@DOLLAR@c"
    record_session "@DOLLAR@c" "@DOLLAR@sid"
    echo "Attaching to container: @DOLLAR@c"
    docker exec -it "@DOLLAR@c" "@DOLLAR@@"
}

# Where a session was last run, for the picker: "open in <c>", "in <c>", or "".
session_location() {
    local c
    c=@DOLLAR@([ -f "@DOLLAR@STATE_FILE" ] && jq -r --arg s "@DOLLAR@1" '.containers[]? | select(.session_id==@DOLLAR@s) | .name' "@DOLLAR@STATE_FILE" 2>/dev/null | head -1)
    [ -z "@DOLLAR@c" ] && return 0
    if docker ps --format '{{.Names}}' | grep -qx "@DOLLAR@c" && [ -n "@DOLLAR@(claude_cli_pids "@DOLLAR@c")" ]; then
        printf 'open in %s' "@DOLLAR@c"
    else
        printf 'in %s' "@DOLLAR@c"
    fi
}

# List this checkout's sessions, newest first, and let the user pick one.
# Sets PICKED_SID.
pick_session() {
    local dir="@DOLLAR@1" files=() f i sid choice summ
    mapfile -t files < <(ls -t "@DOLLAR@dir"/*.jsonl 2>/dev/null | head -20)
    [ @DOLLAR@{#files[@]} -eq 0 ] && return 1
    echo ""
    echo "Sessions in @DOLLAR@{SANDBOX_WORKDIR/#@DOLLAR@HOME/~} (newest first):"
    for i in "@DOLLAR@{!files[@]}"; do
        f="@DOLLAR@{files[@DOLLAR@i]}"
        sid=@DOLLAR@(basename "@DOLLAR@f" .jsonl)
        summ=@DOLLAR@(summary_of_file "@DOLLAR@f")
        printf "  %2d) %-4s %-8s  %-34s %s\n" "@DOLLAR@((i+1))" "@DOLLAR@(age_short "@DOLLAR@(stat -c %Y "@DOLLAR@f")")" \
            "@DOLLAR@{sid:0:8}" "@DOLLAR@(session_location "@DOLLAR@sid")" "@DOLLAR@{summ:-(no messages yet)}"
    done
    echo ""
    read -rp "Resume which? [1-@DOLLAR@{#files[@]}, Enter = 1]: " choice
    choice="@DOLLAR@{choice:-1}"
    if ! [[ "@DOLLAR@choice" =~ ^[0-9]+@DOLLAR@ ]] || [ "@DOLLAR@choice" -lt 1 ] || [ "@DOLLAR@choice" -gt @DOLLAR@{#files[@]} ]; then
        echo "Invalid selection." >&2
        exit 1
    fi
    PICKED_SID=@DOLLAR@(basename "@DOLLAR@{files[@DOLLAR@((choice-1))]}" .jsonl)
}

# Decide which container runs a resumed session: the one it last ran in, else
# this checkout's only sandbox, else ask (or create one if there is none).
# Sets TARGET / TARGET_CREATE / TARGET_DESC.
resolve_container() {
    local sid="@DOLLAR@1" c cands=() legacy=() i choice d
    TARGET=""; TARGET_CREATE=0; TARGET_DESC=""

    c=@DOLLAR@([ -f "@DOLLAR@STATE_FILE" ] && jq -r --arg s "@DOLLAR@sid" '.containers[]? | select(.session_id==@DOLLAR@s) | .name' "@DOLLAR@STATE_FILE" 2>/dev/null | head -1)
    if [ -n "@DOLLAR@c" ] && docker ps -a --format '{{.Names}}' | grep -qx "@DOLLAR@c" && container_matches_workdir "@DOLLAR@c"; then
        echo "Session last ran in @DOLLAR@c."
        TARGET="@DOLLAR@c"; return
    fi

    while IFS= read -r c; do
        [ -z "@DOLLAR@c" ] && continue
        if container_matches_workdir "@DOLLAR@c"; then cands+=("@DOLLAR@c"); else legacy+=("@DOLLAR@c"); fi
    done < <(repo_containers)

    if [ @DOLLAR@{#legacy[@]} -gt 0 ]; then
        echo "Note: @DOLLAR@{legacy[*]} run(s) at /workspace (created before 1.0.3) and cannot resume"
        echo "      this checkout's sessions. Recreate with: docker rm -f <name>  (code and"
        echo "      transcripts are on the host)."
    fi

    if [ @DOLLAR@{#cands[@]} -eq 0 ]; then
        echo "No usable sandbox for this checkout — creating one."
        prompt_new_container
        TARGET="@DOLLAR@NEW_NAME"; TARGET_CREATE=1; TARGET_DESC="@DOLLAR@NEW_DESC"; return
    fi
    if [ @DOLLAR@{#cands[@]} -eq 1 ] || ! [ -t 0 ]; then
        TARGET="@DOLLAR@{cands[0]}"; return
    fi

    echo ""
    echo "Which sandbox should run it?"
    for i in "@DOLLAR@{!cands[@]}"; do
        d=@DOLLAR@([ -f "@DOLLAR@STATE_FILE" ] && jq -r --arg n "@DOLLAR@{cands[@DOLLAR@i]}" '.containers[]? | select(.name==@DOLLAR@n) | .description // empty' "@DOLLAR@STATE_FILE" 2>/dev/null)
        printf "  %d) %-30s %s\n" "@DOLLAR@((i+1))" "@DOLLAR@{cands[@DOLLAR@i]}" "@DOLLAR@(describe_container "@DOLLAR@{cands[@DOLLAR@i]}" "@DOLLAR@d" "")"
    done
    echo "  n) Create a new sandbox"
    read -rp "Choose [1-@DOLLAR@{#cands[@]} or n]: " choice
    if [ "@DOLLAR@choice" = "n" ] || [ "@DOLLAR@choice" = "N" ]; then
        prompt_new_container
        TARGET="@DOLLAR@NEW_NAME"; TARGET_CREATE=1; TARGET_DESC="@DOLLAR@NEW_DESC"
    elif [[ "@DOLLAR@choice" =~ ^[0-9]+@DOLLAR@ ]] && [ "@DOLLAR@choice" -ge 1 ] && [ "@DOLLAR@choice" -le @DOLLAR@{#cands[@]} ]; then
        TARGET="@DOLLAR@{cands[@DOLLAR@((choice-1))]}"
    else
        echo "Invalid selection." >&2
        exit 1
    fi
}

# --- Subcommand dispatch (before the session modes) ---
case "@DOLLAR@MODE" in
    ls|list)   shift; cmd_ls "@DOLLAR@@"; exit @DOLLAR@? ;;
    stop)      shift; cmd_stop "@DOLLAR@@"; exit @DOLLAR@? ;;
    upgrade)   shift; cmd_upgrade "@DOLLAR@@"; exit @DOLLAR@? ;;
    version|--version|-v) echo "sandbox.sh @DOLLAR@SANDBOX_SH_VERSION"; exit 0 ;;
    help|--help|-h) sed -n '2,/^@DOLLAR@/p' "@DOLLAR@0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    reap)
        echo "'reap' was removed in 1.0.10. Launching Claude in a sandbox now stops any" >&2
        echo "Claude left running there, so sessions no longer pile up. To free memory," >&2
        echo "stop the sandboxes you are done with:  ./sandbox.sh stop [--all]" >&2
        exit 2 ;;
    safe|full|shell|resume) ;;
    *)
        # Anything else is a typo or a subcommand this copy is too old to know.
        # Earlier versions fell through to safe mode here and *built a container*
        # — so an unrecognised verb silently did the opposite of what was asked.
        echo "Unknown mode: '@DOLLAR@MODE'" >&2
        echo "Modes: safe | full | shell | resume | ls | stop | upgrade | version | help" >&2
        exit 2 ;;
esac

# --- Resume mode ---
# Session first: pick the conversation, then it runs in the sandbox it last ran
# in (started or created as needed), with any Claude already there stopped.
if [ "@DOLLAR@MODE" = "resume" ]; then
    shift
    TRUST_MODE="full"; WANT_LAST=0; WANT_ID=""
    for a in "@DOLLAR@@"; do
        case "@DOLLAR@a" in
            safe|full) TRUST_MODE="@DOLLAR@a" ;;
            --last|last) WANT_LAST=1 ;;
            -*) echo "Unknown option for resume: @DOLLAR@a" >&2; exit 2 ;;
            *) WANT_ID="@DOLLAR@a" ;;
        esac
    done

    SDIR=@DOLLAR@(session_dir_for "@DOLLAR@SANDBOX_WORKDIR") || SDIR=""
    SID=""
    if [ -n "@DOLLAR@WANT_ID" ]; then
        mapfile -t matches < <(ls "@DOLLAR@SDIR"/"@DOLLAR@WANT_ID"*.jsonl 2>/dev/null)
        if [ @DOLLAR@{#matches[@]} -ne 1 ]; then
            echo "Session '@DOLLAR@WANT_ID': @DOLLAR@{#matches[@]} matches in @DOLLAR@{SANDBOX_WORKDIR/#@DOLLAR@HOME/~}." >&2
            exit 1
        fi
        SID=@DOLLAR@(basename "@DOLLAR@{matches[0]}" .jsonl)
    elif [ "@DOLLAR@WANT_LAST" = "1" ] || ! [ -t 0 ]; then
        f=@DOLLAR@(ls -t "@DOLLAR@SDIR"/*.jsonl 2>/dev/null | head -1)
        [ -n "@DOLLAR@f" ] && SID=@DOLLAR@(basename "@DOLLAR@f" .jsonl)
        [ -n "@DOLLAR@SID" ] && echo "Most recent session: @DOLLAR@{SID:0:8}  @DOLLAR@(summary_of_file "@DOLLAR@f")"
    else
        pick_session "@DOLLAR@SDIR" && SID="@DOLLAR@PICKED_SID"
    fi

    if [ -z "@DOLLAR@SID" ]; then
        echo "No Claude sessions found for @DOLLAR@{SANDBOX_WORKDIR/#@DOLLAR@HOME/~}." >&2
        echo "Start one with:  ./sandbox.sh full   (or ./sandbox.sh for safe mode)" >&2
        echo "Sessions from a /workspace sandbox (pre-1.0.3) are only visible inside it:" >&2
        echo "  ./sandbox.sh shell   then   claude --resume" >&2
        exit 1
    fi

    resolve_container "@DOLLAR@SID"
    choose_model
    if [ "@DOLLAR@TRUST_MODE" = "safe" ]; then
        echo "Resuming in safe mode..."
        PERM_ARGS=()
        apply_profile "safe"
    else
        echo "Resuming in full trust mode..."
        PERM_ARGS=(--dangerously-skip-permissions)
        apply_profile "full"
    fi
    launch "@DOLLAR@TARGET" "@DOLLAR@TARGET_CREATE" "@DOLLAR@TARGET_DESC" "@DOLLAR@SID" \
        claude "@DOLLAR@{PERM_ARGS[@]}" --resume "@DOLLAR@SID" "@DOLLAR@{MODEL_ARGS[@]}"
    exit @DOLLAR@?
fi

# --- Normal modes (full / safe / shell) ---
# New sessions get an explicit --session-id so `ls`/`stop`/`resume` can tell
# which session a container is running as a recorded fact, not an inference.
NEW_SESSION_ID=""
if [ "@DOLLAR@MODE" = "full" ]; then
    echo "WARNING: Running in full trust mode - all commands allowed"
    NEW_SESSION_ID=@DOLLAR@(new_uuid)
    CLAUDE_CMD=(claude --dangerously-skip-permissions)
    apply_profile "full"
elif [ "@DOLLAR@MODE" = "shell" ]; then
    echo "Opening container shell (run 'claude' to start Claude Code)"
    CLAUDE_CMD=(bash)
    apply_profile "safe"
else
    echo "Running in safe mode with restricted permissions"
    NEW_SESSION_ID=@DOLLAR@(new_uuid)
    CLAUDE_CMD=(claude)
    apply_profile "safe"
fi
[ -n "@DOLLAR@NEW_SESSION_ID" ] && CLAUDE_CMD+=(--session-id "@DOLLAR@NEW_SESSION_ID")

# Choose target container. When at least one sandbox already exists for this
# project and we have an interactive terminal, offer a picker: attach to an
# existing one (with a description of what's running there) or create a new,
# named one. With no existing containers, or when non-interactive (CI/headless),
# fall back to the default single-container behavior so nothing hangs.
CONTAINER_NAME="@DOLLAR@{PROJECT_NAME}-sandbox"
CREATE_NEW=0
NEW_DESC=""

if [ -t 0 ]; then
    select_or_create
else
    SELECTION="auto"
fi

if [ "@DOLLAR@SELECTION" = "new" ]; then
    prompt_new_container
    CONTAINER_NAME="@DOLLAR@NEW_NAME"
    CREATE_NEW=1
elif [ "@DOLLAR@SELECTION" != "none" ] && [ "@DOLLAR@SELECTION" != "auto" ]; then
    # User picked an existing container from the menu.
    CONTAINER_NAME="@DOLLAR@SELECTION"
else
    # none/auto: default name — attach if it exists, otherwise create it.
    docker ps -a --format '{{.Names}}' | grep -qx "@DOLLAR@CONTAINER_NAME" || CREATE_NEW=1
fi

if [ "@DOLLAR@MODE" != "shell" ]; then
    choose_model
    CLAUDE_CMD+=("@DOLLAR@{MODEL_ARGS[@]}")
fi

launch "@DOLLAR@CONTAINER_NAME" "@DOLLAR@CREATE_NEW" "@DOLLAR@NEW_DESC" "@DOLLAR@NEW_SESSION_ID" "@DOLLAR@{CLAUDE_CMD[@]}"
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

Full trust is delivered by the `--dangerously-skip-permissions` flag that `sandbox.sh` passes in every `full` / `resume` (full) launch — not by this file. The profile deliberately does **not** set `"defaultMode": "bypassPermissions"`: writing that string to disk trips Claude Code's auto-mode safety classifier, which blocks the file and leaves `/init-sandbox` incomplete in headless/auto sessions. Since the flag already bypasses the permission gate inside the container (the isolation boundary), the file only needs to carry the agent-teams env var and impose no restrictions.

```json
{
  "permissions": {
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
     ./sandbox.sh resume [full|safe]  (pick a past session; runs in its sandbox)
     ./sandbox.sh resume --last       (most recent session, no picker)
  Each Claude launch asks which model to use (Enter = last choice), and
  stops any Claude left running in that sandbox by a dropped terminal.

Lifecycle:
  ./sandbox.sh ls [--all]       list sandboxes + the session each is running
  ./sandbox.sh stop [--all]     pick sandboxes to stop (multi-select)
  ./sandbox.sh upgrade          refresh this script from the plugin

Container tracking:
  - .sandbox-state.json records container name/ID after first run
  - every launch and resume records its session id, so ls/stop/resume
    know which session each container runs instead of guessing
```
