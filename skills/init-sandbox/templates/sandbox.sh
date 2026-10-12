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
# This script upgrades itself: when the installed claude-sandbox plugin has a
# newer sandbox.sh, it replaces this copy (keeping a .bak) and re-runs your
# command. It never downgrades. Set SANDBOX_NO_AUTO_UPGRADE=1 to turn it off.
#
# When a sandbox already exists for this project and you run full/safe/shell in
# an interactive terminal, you get a picker: attach to an existing container
# (showing what's running there + its description) or create a new, named one.
# With no existing container, or when non-interactive, it uses the default
# <project>-sandbox container.

SANDBOX_SH_VERSION="1.0.11"

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
    local cwd="$1" base="$HOME/.claude/projects" e
    [ -d "$base" ] || return 1
    for e in "$(printf '%s' "$cwd" | sed 's#/#-#g')" \
             "$(printf '%s' "$cwd" | sed 's#[/.]#-#g')"; do
        [ -d "$base/$e" ] && { printf '%s' "$base/$e"; return 0; }
    done
    return 1
}

# One-line topic for a transcript file: the newest rollup summary Claude wrote,
# falling back to the opening user message.
summary_of_file() {
    local f="$1" s
    [ -f "$f" ] || return 0
    # Read only the lines that matter: transcripts run to many MB, and the
    # resume picker summarises a screenful of them.
    s=$(tac "$f" 2>/dev/null | grep -m1 '"type": *"summary"' | jq -r '.summary // empty' 2>/dev/null)
    if [ -z "$s" ]; then
        # No rollup summary yet — fall back to the first real user message,
        # skipping the synthetic blocks Claude injects (slash-command echoes,
        # caveat preambles, hook output) which otherwise read as gibberish.
        s=$(grep -m20 '"type": *"user"' "$f" 2>/dev/null | jq -rn 'first(inputs
                    | .message.content
                    | if type=="array" then (map(select(.type=="text").text) | join(" ")) else tostring end
                    | select(test("^<(local-command|command-name|command-message|system-reminder)") | not))
                    // empty' 2>/dev/null)
    fi
    [ -n "$s" ] && printf '%s' "$s" \
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
    docker top "$1" -eo pid,args 2>/dev/null | tail -n +2 | awk '
        $2 ~ /(^|\/)claude(\.exe)?$/ { print $1; next }
        $2 ~ /(^|\/)node$/ && $3 ~ /((^|\/)claude|claude-code\/cli\.js)$/ { print $1 }'
}

# Host PID of the (first) claude process running inside a container, if any.
container_claude_pid() {
    claude_cli_pids "$1" | head -1
}

# The cwd a container's claude process is running in (its session key).
container_cwd() {
    local pid="$1" c="$2" d=""
    [ -n "$pid" ] && d=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    [ -z "$d" ] && d=$(docker inspect --format '{{.Config.WorkingDir}}' "$c" 2>/dev/null)
    printf '%s' "$d"
}

# Host path of the repo bind-mounted into a container (excludes the shared
# ~/.claude and ~/.config/gh mounts), used to locate that repo's state file.
container_repo_dir() {
    docker inspect --format \
      '{{range .Mounts}}{{if eq .Type "bind"}}{{if and (ne .Destination "/home/claude/.claude") (ne .Destination "/home/claude/.config/gh")}}{{.Source}}
{{end}}{{end}}{{end}}' "$1" 2>/dev/null | grep -v '^$' | head -1
}

# The session id sandbox.sh recorded for a container, if any (authoritative).
recorded_session_id() {
    local c="$1" repo state
    repo=$(container_repo_dir "$c")
    state="${repo}/.sandbox-state.json"
    [ -n "$repo" ] && [ -f "$state" ] || return 0
    jq -r --arg n "$c" '.containers[]? | select(.name==$n) | .session_id // empty' "$state" 2>/dev/null
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
    local c="$1" claimants="${2:-1}"
    local sid="" summ="" kind="-" pid cwd dir f pstart mtime

    sid=$(recorded_session_id "$c")
    pid=$(container_claude_pid "$c")
    cwd=$(container_cwd "$pid" "$c")
    dir=$(session_dir_for "$cwd") || dir=""

    if [ -n "$sid" ] && [ -n "$dir" ] && [ -f "$dir/$sid.jsonl" ]; then
        kind="fact"
        summ=$(summary_of_file "$dir/$sid.jsonl")
    elif [ -n "$pid" ] && [ "$claimants" -gt 1 ]; then
        # Several live containers share this transcript directory; any pick
        # would be a coin flip. Say so instead of guessing.
        kind="ambiguous"
    elif [ -n "$pid" ] && [ -n "$dir" ]; then
        pstart=$(ps -o lstart= -p "$pid" 2>/dev/null)
        pstart=$([ -n "$pstart" ] && date -d "$pstart" +%s 2>/dev/null || echo 0)
        for f in $(ls -t "$dir"/*.jsonl 2>/dev/null); do
            mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
            if [ "$mtime" -ge "$pstart" ]; then
                sid=$(basename "$f" .jsonl)
                summ=$(summary_of_file "$f")
                kind="guess"
                break
            fi
        done
    fi

    printf '%s\x1f%s\x1f%s' "$sid" "$summ" "$kind"
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
    local c="$1" claimants="${2:-1}" pid cwd dir f ts=0 s sid
    sid=$(recorded_session_id "$c")
    pid=$(container_claude_pid "$c")
    cwd=$(container_cwd "$pid" "$c")
    dir=$(session_dir_for "$cwd") || dir=""

    if [ -n "$dir" ] && [ -n "$sid" ] && [ -f "$dir/$sid.jsonl" ]; then
        ts=$(stat -c %Y "$dir/$sid.jsonl" 2>/dev/null || echo 0)
    elif [ -n "$dir" ] && [ "$claimants" -le 1 ]; then
        f=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
        [ -n "$f" ] && ts=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    fi

    if [ "$ts" = "0" ]; then
        s=$(docker inspect --format '{{.State.StartedAt}}' "$c" 2>/dev/null)
        ts=$(date -d "$s" +%s 2>/dev/null || echo 0)
    fi
    echo "$ts"
}

# Human-readable age from an epoch, e.g. "3d", "5h", "12m".
age_short() {
    local then="$1" now secs
    now=$(date +%s)
    [ -z "$then" ] || [ "$then" = "0" ] && { echo "?"; return; }
    secs=$(( now - then ))
    if   [ "$secs" -ge 86400 ]; then echo "$(( secs / 86400 ))d"
    elif [ "$secs" -ge 3600 ];  then echo "$(( secs / 3600 ))h"
    else echo "$(( secs / 60 ))m"; fi
}

# =============================================================================
# Container helpers
# =============================================================================

# --- Helper: replace the containers list, keeping any other state keys ---
write_containers() {
    local base="{}"
    [ -f "$STATE_FILE" ] && base=$(jq '.' "$STATE_FILE" 2>/dev/null || echo "{}")
    echo "$base" | jq --argjson c "$1" '.containers = $c' > "$STATE_FILE.tmp" \
        && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

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

    write_containers "$entries"
    echo "Container recorded in .sandbox-state.json"
}

# --- Helper: record which Claude session a container is running ---
# Makes `ls`/`stop` able to report the session id as a fact rather than a guess.
record_session() {
    local name="$1" sid="$2"
    [ -n "$sid" ] || return 0
    local entries="[]"
    [ -f "$STATE_FILE" ] && entries=$(jq '.containers // []' "$STATE_FILE" 2>/dev/null || echo "[]")
    # Ensure an entry exists for this container, then stamp the session onto it.
    if [ "$(echo "$entries" | jq --arg n "$name" '[.[] | select(.name==$n)] | length')" = "0" ]; then
        entries=$(echo "$entries" | jq --arg n "$name" '. + [{name: $n, description: ""}]')
    fi
    # A session runs in one place: resuming it here clears it from any other
    # container that recorded it, so ls and resume never show it twice.
    entries=$(echo "$entries" | jq \
        --arg n "$name" --arg s "$sid" --arg t "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '[.[] | if .name == $n then . + {session_id: $s, session_started_at: $t}
                elif .session_id == $s then del(.session_id, .session_started_at)
                else . end]')
    write_containers "$entries"
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
    local container="$1"
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "Starting stopped container: $container"
        docker start "$container"
    fi
}

# --- Helper: update Claude Code, at most once a day per container ---
# Runs as root because the CLI is installed in the root-owned npm global dir.
# The stamp is keyed by container id, so a recreated container (same name, new
# image layer) is always updated on first launch. SANDBOX_UPDATE=1 forces it.
maybe_update_claude() {
    local container="$1" id stamp dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-sandbox"
    id=$(docker inspect --format '{{.Id}}' "$container" 2>/dev/null | head -c 12)
    stamp="$dir/claude-updated-$id"
    if [ "${SANDBOX_UPDATE:-}" != "1" ] && [ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ]; then
        echo "Claude Code: last update check $(age_short "$(stat -c %Y "$stamp")") ago (daily; SANDBOX_UPDATE=1 to force)."
        return 0
    fi
    echo "Updating Claude Code (daily check)..."
    if docker exec -u root "$container" npm install -g --no-fund --no-audit --loglevel=error @anthropic-ai/claude-code@latest >/dev/null; then
        mkdir -p "$dir" && touch "$stamp"
        echo "Claude Code: $(docker exec "$container" claude --version 2>/dev/null | head -1)"
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
    ps -eo args= 2>/dev/null | awk -v c="$1" '
        $1 ~ /(^|\/)docker$/ && $2 == "exec" { for (i = 3; i <= NF; i++) if ($i == c) { n++; break } }
        END { print n + 0 }'
}

# A host PID and all its descendants (host PIDs), from the container's table.
descendants_of() {
    local c="$1" root="$2"
    docker top "$c" -eo pid,ppid 2>/dev/null | tail -n +2 | awk -v r="$root" '
        { kids[$2] = kids[$2] " " $1 }
        END { q = r; while (q != "") { split(q, a, " "); q = ""
                for (i in a) if (a[i] != "") { print a[i]; q = q " " kids[a[i]] } } }'
}

# The PID a host process has inside its container's PID namespace.
inner_pid() {
    awk '/^NSpid:/ { print $NF }' "/proc/$1/status" 2>/dev/null
}

# Resident memory of a host PID, in MB.
rss_mb() {
    awk '/^VmRSS:/ { printf "%d", $2 / 1024 }' "/proc/$1/status" 2>/dev/null
}

# Make sure no Claude is running in a container before starting one.
# Orphans (no terminal attached) are stopped without asking; if a terminal is
# still attached, the user decides. Exits the script if they decline.
clear_live_claude() {
    local c="$1" pids=() p clients total=0 ok
    mapfile -t pids < <(claude_cli_pids "$c")
    [ ${#pids[@]} -eq 0 ] && return 0
    for p in "${pids[@]}"; do total=$(( total + $(rss_mb "$p" || echo 0) )); done
    clients=$(attached_clients "$c")

    if [ "$clients" -gt 0 ]; then
        echo ""
        echo "$c already has ${#pids[@]} Claude process(es) running (~${total} MB),"
        echo "and $clients terminal(s) are attached to this container — probably a session"
        echo "you have open elsewhere. Starting here will close it there; its transcript is saved."
        if ! [ -t 0 ]; then
            echo "Refusing to interrupt it without a terminal to confirm." >&2
            exit 1
        fi
        read -rp "Stop it and continue here? [y/N]: " ok
        case "$ok" in
            y|Y|yes|YES) ;;
            *) echo "Cancelled — switch to the terminal where it is open."; exit 0 ;;
        esac
    else
        echo "Stopping ${#pids[@]} orphaned Claude process(es) in $c (~${total} MB; terminal gone, transcript saved)."
    fi

    # Signal Claude and everything it spawned (shells, MCP servers), via the
    # container's own PID numbers so this works whatever uid the container uses.
    local all=() inner=() q
    for p in "${pids[@]}"; do mapfile -t -O "${#all[@]}" all < <(descendants_of "$c" "$p"); done
    for q in "${all[@]}"; do p=$(inner_pid "$q"); [ -n "$p" ] && inner+=("$p"); done
    [ ${#inner[@]} -eq 0 ] && return 0
    # `kill` is the shell builtin here: slim images ship no procps.
    docker exec -u root "$c" sh -c 'kill -TERM "$@"' sh "${inner[@]}" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -z "$(claude_cli_pids "$c")" ] && break
        sleep 0.5
    done
    docker exec -u root "$c" sh -c 'kill -KILL "$@"' sh "${inner[@]}" 2>/dev/null
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
    last=$([ -f "$STATE_FILE" ] && jq -r '.last_model // empty' "$STATE_FILE" 2>/dev/null)
    last="${last:-default}"

    if [ -n "${SANDBOX_MODEL:-}" ]; then
        m="$SANDBOX_MODEL"
    elif ! [ -t 0 ]; then
        m="$last"
    else
        if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            mapfile -t ids < <(curl -fsS --max-time 5 "https://api.anthropic.com/v1/models?limit=100" \
                -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" 2>/dev/null \
                | jq -r '.data[]? | "\(.id)\t\(.display_name)"' 2>/dev/null)
        fi
        echo ""
        echo "Model for this session (aliases always mean the latest of that family):"
        for i in "${!MODEL_ALIASES[@]}"; do
            printf "  %d) %-8s %s\n" "$((i+1))" "${MODEL_ALIASES[$i]}" "${MODEL_NOTES[$i]}"
        done
        if [ ${#ids[@]} -gt 0 ]; then
            echo "  Specific models available to your API key:"
            for i in "${!ids[@]}"; do
                printf "  %d) %-26s %s\n" "$(( ${#MODEL_ALIASES[@]} + i + 1 ))" "${ids[$i]%%$'\t'*}" "${ids[$i]#*$'\t'}"
            done
        fi
        echo "  o) other — type a model name (e.g. claude-opus-5-5, opus[1m])"
        echo "  (You can still switch inside Claude with /model.)"
        read -rp "Choose [Enter = $last]: " choice
        if [ -z "$choice" ]; then
            m="$last"
        elif [ "$choice" = "o" ] || [ "$choice" = "O" ]; then
            read -rp "Model name: " m
            m="${m:-$last}"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#MODEL_ALIASES[@]} ]; then
            m="${MODEL_ALIASES[$((choice-1))]}"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt ${#MODEL_ALIASES[@]} ] \
             && [ "$choice" -le $(( ${#MODEL_ALIASES[@]} + ${#ids[@]} )) ]; then
            m="${ids[$((choice - ${#MODEL_ALIASES[@]} - 1))]%%$'\t'*}"
        else
            m="$choice"   # typed a name directly
        fi
        # Remember it for next time.
        local base="{}"
        [ -f "$STATE_FILE" ] && base=$(jq '.' "$STATE_FILE" 2>/dev/null || echo "{}")
        echo "$base" | jq --arg m "$m" '.last_model = $m' > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    fi

    [ -n "$m" ] && [ "$m" != "default" ] && MODEL_ARGS=(--model "$m")
    echo "Model: $m"
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
    # `docker top` rejects a format without a PID column ("Couldn't find PID
    # field in ps output"), so ask for pid,args and drop the pid.
    args=$(docker top "$c" -eo pid,args 2>/dev/null | tail -n +2 | cut -d' ' -f2-)
    if [ -n "$(claude_cli_pids "$c")" ]; then
        echo "claude"
    elif echo "$args" | grep -qiE '(^|/| )codex( |$)|codex'; then
        echo "codex"
    elif echo "$args" | grep -qE '(^|/)(ba)?sh( |$)'; then
        echo "shell"
    fi
}

# --- Helper: best-effort summary of the newest Claude session for this repo ---
# Used only by the attach-or-create picker, where a repo-wide hint is enough.
session_summary() {
    local dir f
    dir=$(session_dir_for "$SANDBOX_WORKDIR") || return 0
    f=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
    [ -n "$f" ] && summary_of_file "$f"
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

# =============================================================================
# Lifecycle subcommands: ls / stop / upgrade
# =============================================================================

# Enumerate sandbox containers. Scope "repo" (default) uses this project's state
# file plus name match; scope "all" finds every sandbox container on the host.
enumerate_sandboxes() {
    local scope="${1:-repo}"
    if [ "$scope" = "all" ]; then
        # A sandbox is any container whose image or name marks it as one.
        { docker ps -a --filter "name=sandbox" --format '{{.Names}}' 2>/dev/null
          docker ps -a --filter "ancestor=claude-sandbox" --format '{{.Names}}' 2>/dev/null
        } | sort -u
    else
        { [ -f "$STATE_FILE" ] && jq -r '.containers[]?.name' "$STATE_FILE" 2>/dev/null
          docker ps -a --filter "name=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null
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
    for n in "$@"; do
        [ -z "$n" ] && continue
        pid=$(container_claude_pid "$n")
        if [ -n "$pid" ] && [ -z "$(recorded_session_id "$n")" ]; then
            cwd=$(container_cwd "$pid" "$n")
            dir=$(session_dir_for "$cwd") || dir=""
            if [ -n "$dir" ]; then
                by_dir["$dir"]=$(( ${by_dir["$dir"]:-0} + 1 ))
                dir_of["$n"]="$dir"
            fi
        fi
    done
    for n in "$@"; do
        [ -z "$n" ] && continue
        dir="${dir_of[$n]:-}"
        if [ -n "$dir" ]; then CLAIMS_BY_NAME["$n"]="${by_dir["$dir"]:-1}"
        else CLAIMS_BY_NAME["$n"]=1; fi
    done
}

# Render the shared sandbox table. Populates the parallel arrays ROW_NAMES /
# ROW_STATUS so callers (ls, stop) can act on the same numbering the user sees.
# Args: scope [--number]
render_table() {
    local scope="$1" numbered="$2"
    ROW_NAMES=(); ROW_STATUS=(); ROW_CLAIMANTS=()
    local n st tool sid summ kind idle repo desc line i=0

    while IFS= read -r n; do
        [ -z "$n" ] && continue
        st=$(docker ps -a --filter "name=^${n}$" --format '{{.Status}}' 2>/dev/null)
        [ -z "$st" ] && continue
        ROW_NAMES+=("$n"); ROW_STATUS+=("$st")
    done < <(enumerate_sandboxes "$scope")

    if [ ${#ROW_NAMES[@]} -eq 0 ]; then
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
    build_claims "${_all[@]}"
    for i in "${!ROW_NAMES[@]}"; do
        ROW_CLAIMANTS+=("${CLAIMS_BY_NAME[${ROW_NAMES[$i]}]:-1}")
    done

    printf "\n"
    if [ "$numbered" = "--number" ]; then
        printf "  %-3s %-34s %-16s %-7s %-9s %-40s %s\n" "#" "CONTAINER" "STATUS" "TOOL" "SESSION" "TOPIC" "IDLE"
        printf "  %-3s %-34s %-16s %-7s %-9s %-40s %s\n" "---" "$(printf '%.0s-' {1..34})" "$(printf '%.0s-' {1..16})" "-------" "---------" "$(printf '%.0s-' {1..40})" "----"
    else
        printf "  %-34s %-16s %-7s %-9s %-40s %s\n" "CONTAINER" "STATUS" "TOOL" "SESSION" "TOPIC" "IDLE"
        printf "  %-34s %-16s %-7s %-9s %-40s %s\n" "$(printf '%.0s-' {1..34})" "$(printf '%.0s-' {1..16})" "-------" "---------" "$(printf '%.0s-' {1..40})" "----"
    fi

    local ambiguous=0 stacked=0
    for i in "${!ROW_NAMES[@]}"; do
        n="${ROW_NAMES[$i]}"; st="${ROW_STATUS[$i]}"
        tool=$(running_tool "$n"); [ -z "$tool" ] && tool="-"
        if [ "$tool" = "claude" ]; then
            # Several Claudes in one sandbox are leftovers from dropped terminals.
            local nc; nc=$(claude_cli_pids "$n" | wc -l)
            [ "$nc" -gt 1 ] && { tool="claude×$nc"; stacked=1; }
        fi
        IFS=$'\x1f' read -r sid summ kind <<< "$(container_session "$n" "${ROW_CLAIMANTS[$i]}")"
        idle=$(age_short "$(last_activity_epoch "$n" "${ROW_CLAIMANTS[$i]}")")
        repo=$(container_repo_dir "$n")
        desc=""
        [ -n "$repo" ] && [ -f "$repo/.sandbox-state.json" ] && \
            desc=$(jq -r --arg n "$n" '.containers[]? | select(.name==$n) | .description // empty' "$repo/.sandbox-state.json" 2>/dev/null)

        # Short session id: bare when recorded, ~ when inferred, ? when several
        # live containers share one transcript directory and it cannot be told.
        local sid_disp="-"
        if [ "$kind" = "ambiguous" ]; then
            sid_disp="?shared"
            ambiguous=1
        elif [ -n "$sid" ]; then
            sid_disp="${sid:0:8}"
            [ "$kind" = "guess" ] && sid_disp="~${sid:0:8}"
        fi
        # Prefer the live session topic; fall back to the typed description.
        local topic="${summ:-$desc}"
        [ -n "$topic" ] && topic="\"${topic}\""
        [ -z "$topic" ] && topic="-"

        if [ "$numbered" = "--number" ]; then
            printf "  %-3s %-34s %-16s %-7s %-9s %-40s %s\n" \
                "$((i+1))" "$n" "${st:0:16}" "$tool" "$sid_disp" "${topic:0:40}" "$idle"
        else
            printf "  %-34s %-16s %-7s %-9s %-40s %s\n" \
                "$n" "${st:0:16}" "$tool" "$sid_disp" "${topic:0:40}" "$idle"
        fi
    done
    printf "\n"
    printf "  SESSION: Claude session id — bare = recorded at launch, ~ = inferred\n"
    printf "  IDLE   : time since this session's transcript was last written\n"
    if [ "$stacked" = "1" ]; then
        printf "  claude×N — several Claudes in one sandbox, left behind by dropped\n"
        printf "             terminals. The next launch there stops the extras.\n"
    fi
    if [ "$ambiguous" = "1" ]; then
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
    local input="$1" max="$2" out=() tok a b i
    input=$(echo "$input" | tr ',' ' ')
    for tok in $input; do
        case "$tok" in
            all|ALL|a|A)
                for ((i=1; i<=max; i++)); do out+=("$i"); done ;;
            *-*)
                a=${tok%%-*}; b=${tok##*-}
                [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
                for ((i=a; i<=b; i++)); do out+=("$i"); done ;;
            *)
                [[ "$tok" =~ ^[0-9]+$ ]] || return 1
                out+=("$tok") ;;
        esac
    done
    [ ${#out[@]} -eq 0 ] && return 1
    printf '%s\n' "${out[@]}" | sort -un | awk -v m="$max" '$1>=1 && $1<=m'
}

cmd_ls() {
    local scope="repo"
    [ "$1" = "--all" ] && scope="all"
    render_table "$scope" ""
}

cmd_stop() {
    local scope="repo"
    [ "$1" = "--all" ] && scope="all"

    if ! [ -t 0 ]; then
        echo "Error: 'stop' is interactive and needs a terminal. For scripts, use: docker stop <name>" >&2
        exit 1
    fi

    render_table "$scope" "--number" || exit 1

    echo "Stopping is non-destructive: code and ~/.claude transcripts are on the host,"
    echo "so a stopped sandbox restarts exactly where it left off."
    echo ""
    read -rp "Stop which sandboxes? [e.g. 1 3 5 | 2-4 | all | q to cancel]: " choice
    case "$choice" in
        q|Q|"") echo "Cancelled."; exit 0 ;;
    esac

    local picks
    picks=$(parse_selection "$choice" "${#ROW_NAMES[@]}") || { echo "Invalid selection." >&2; exit 1; }
    [ -z "$picks" ] && { echo "Nothing selected."; exit 0; }

    echo ""
    echo "Will stop:"
    local n tool sid summ kind live=0
    while IFS= read -r i; do
        n="${ROW_NAMES[$((i-1))]}"
        tool=$(running_tool "$n")
        # Same claimant count the table used, so the confirmation cannot name a
        # session the table just reported as unidentifiable.
        IFS=$'\x1f' read -r sid summ kind <<< "$(container_session "$n" "${ROW_CLAIMANTS[$((i-1))]}")"
        printf "  - %s" "$n"
        if [ "$kind" = "ambiguous" ]; then
            printf "  session ?shared (cannot be identified)"
        else
            [ -n "$sid" ] && printf "  session %s" "${sid:0:8}"
            [ -n "$summ" ] && printf "  \"%s\"" "$summ"
        fi
        if [ "$tool" = "claude" ]; then printf "   [LIVE claude — will be interrupted]"; live=1; fi
        printf "\n"
    done <<< "$picks"
    echo ""
    if [ "$live" = "1" ]; then
        echo "One or more have a live Claude session. The transcript is already on the host,"
        echo "so you can pick it back up with:  ./sandbox.sh resume   (or  claude --resume <id>)"
        echo ""
    fi

    read -rp "Confirm stop? [y/N]: " ok
    case "$ok" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac

    while IFS= read -r i; do
        n="${ROW_NAMES[$((i-1))]}"
        if docker ps --format '{{.Names}}' | grep -q "^${n}$"; then
            docker stop "$n" >/dev/null && echo "  stopped  $n"
        else
            echo "  already stopped  $n"
        fi
    done <<< "$picks"
    echo ""
    echo "Restart any of them with: docker start <name>  — or just ./sandbox.sh in that repo."
}

# Locate the installed plugin so `upgrade` can re-copy the canonical template.
find_plugin_dir() {
    local c
    if [ -n "$CLAUDE_SANDBOX_PLUGIN_DIR" ] && [ -f "$CLAUDE_SANDBOX_PLUGIN_DIR/skills/init-sandbox/templates/sandbox.sh" ]; then
        printf '%s' "$CLAUDE_SANDBOX_PLUGIN_DIR"; return 0
    fi
    # Highest installed version in the plugin cache wins.
    c=$(ls -d "$HOME"/.claude/plugins/cache/*/claude-sandbox/*/ 2>/dev/null | sort -V | tail -1)
    [ -n "$c" ] && [ -f "${c}skills/init-sandbox/templates/sandbox.sh" ] && { printf '%s' "${c%/}"; return 0; }
    for c in "$HOME"/.claude/plugins/marketplaces/*claude-sandbox*/ "$HOME"/Projects/claude-sandbox-plugin/; do
        [ -f "${c}skills/init-sandbox/templates/sandbox.sh" ] && { printf '%s' "${c%/}"; return 0; }
    done
    return 1
}

# True when $1 is a strictly older version than $2.
version_lt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# Version stamp of a sandbox.sh on disk ("1.0.0" if it predates the stamp).
sh_version_of() {
    local f="$1" v
    v=$(grep -m1 '^SANDBOX_SH_VERSION=' "$f" 2>/dev/null | cut -d'"' -f2)
    printf '%s' "${v:-1.0.0}"
}

# Refresh one repo's sandbox.sh from the plugin. Echoes a status word.
upgrade_one() {
    local repo="$1" src="$2" force="$3"
    local dst="$repo/sandbox.sh" cur new
    [ -f "$dst" ] || { echo "skip"; return; }
    cur=$(sh_version_of "$dst")
    new=$(sh_version_of "$src")
    if [ "$cur" = "$new" ] && [ "$force" != "--force" ]; then echo "current"; return; fi
    # Never walk a repo backwards. The plugin cache can legitimately be older
    # than a repo (a release pushed but not yet installed), and copying it over
    # would silently revert the repo to the older script.
    if version_lt "$new" "$cur" && [ "$force" != "--force" ]; then
        echo "refused: plugin has v$new, repo already has v$cur (use --force to override)"
        return
    fi
    cp "$dst" "$dst.bak-$cur" 2>/dev/null
    cp "$src" "$dst" && chmod +x "$dst" && echo "upgraded $cur -> $new"
}

# Report repos whose generated compose still mounts the repo at /workspace.
# Fixing that needs the container recreated, which this script will not do
# silently — it changes the session key, so it is surfaced, not automated.
check_compose_drift() {
    local repo="$1" f="$repo/docker-compose.sandbox.yml"
    [ -f "$f" ] || return 1
    grep -q 'SANDBOX_REPO_ROOT' "$f" 2>/dev/null && return 1
    return 0
}

cmd_upgrade() {
    local all=0 force=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --all) all=1; shift ;;
            --force) force="--force"; shift ;;
            *) echo "Unknown option for upgrade: $1" >&2; exit 1 ;;
        esac
    done

    local plugin src
    plugin=$(find_plugin_dir) || {
        echo "Error: could not locate the claude-sandbox plugin." >&2
        echo "Set CLAUDE_SANDBOX_PLUGIN_DIR to the plugin root and retry." >&2
        exit 1
    }
    src="$plugin/skills/init-sandbox/templates/sandbox.sh"
    echo "Plugin template: $src  (v$(sh_version_of "$src"))"
    echo ""

    local repos=() drift=()
    if [ "$all" = "1" ]; then
        mapfile -t repos < <(find "$HOME" -maxdepth 4 -name sandbox.sh -not -path "*/node_modules/*" \
            -not -path "$plugin/*" -printf '%h\n' 2>/dev/null | sort -u)
    else
        repos=("$SCRIPT_DIR")
    fi

    local r res
    for r in "${repos[@]}"; do
        res=$(upgrade_one "$r" "$src" "$force")
        printf "  %-50s %s\n" "${r/#$HOME/~}" "$res"
        check_compose_drift "$r" && drift+=("$r")
    done

    if [ ${#drift[@]} -gt 0 ]; then
        echo ""
        echo "These repos still generate a /workspace mount (pre-1.0.3 compose file)."
        echo "sandbox.sh is now current, but the session key only becomes shared once"
        echo "the compose file is regenerated AND the container recreated:"
        for r in "${drift[@]}"; do echo "    ${r/#$HOME/~}"; done
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
    [ "$(docker inspect --format '{{.Config.WorkingDir}}' "$1" 2>/dev/null)" = "$SANDBOX_WORKDIR" ]
}

# Existing containers of this repo, one per line.
repo_containers() {
    local n
    while IFS= read -r n; do
        [ -n "$n" ] && docker ps -a --filter "name=^${n}$" --format '{{.Names}}' 2>/dev/null
    done < <(enumerate_sandboxes "repo")
}

# First free default container name for this project.
suggest_name() {
    local s="${PROJECT_NAME}-sandbox" k=2
    while docker ps -a --format '{{.Names}}' | grep -qx "$s"; do
        s="${PROJECT_NAME}-sandbox-${k}"; k=$((k+1))
    done
    printf '%s' "$s"
}

# Ask for a new sandbox's name and description. Sets NEW_NAME / NEW_DESC.
prompt_new_container() {
    local suggest
    suggest=$(suggest_name)
    NEW_NAME="$suggest"; NEW_DESC=""
    [ -t 0 ] || return 0
    read -rp "Name for new sandbox [${suggest}]: " NEW_NAME
    NEW_NAME="${NEW_NAME:-$suggest}"
    if docker ps -a --format '{{.Names}}' | grep -qx "$NEW_NAME"; then
        echo "A container named '$NEW_NAME' already exists — attach to it instead, or pick another name." >&2
        exit 1
    fi
    read -rp "Short description (what's this sandbox for?): " NEW_DESC
}

# Build and start a new sandbox container, detached.
create_container() {
    local name="$1" desc="$2" proj
    echo "Creating new container: $name"
    export SANDBOX_CONTAINER_NAME="$name"

    # Each container is its own compose project so multiple sandboxes can
    # coexist in one repo (compose otherwise treats the service as a singleton).
    proj="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//')"
    [ -z "$proj" ] && proj="sandbox"

    # The base compose mounts the main repo at its host path. A worktree created
    # OUTSIDE that tree is not covered by that mount, so add a runtime override
    # that also mounts the worktree at its host path. Standard repos and
    # worktrees created INSIDE the repo tree are subpaths of the repo mount and
    # need nothing extra.
    local compose_args=(-f "$SCRIPT_DIR/docker-compose.sandbox.yml")
    local override="$SCRIPT_DIR/.sandbox-worktree.override.yml"
    rm -f "$override"
    case "$SANDBOX_WORKDIR/" in
        "$SANDBOX_REPO_ROOT/"*) : ;;
        *)
            cat > "$override" <<YAML
services:
  claude-sandbox:
    volumes:
      - $SANDBOX_WORKDIR:$SANDBOX_WORKDIR
YAML
            compose_args+=(-f "$override")
            echo "Worktree outside repo tree — added mount override for $SANDBOX_WORKDIR"
            ;;
    esac

    docker compose -p "$proj" "${compose_args[@]}" build
    docker compose -p "$proj" "${compose_args[@]}" up -d claude-sandbox
    record_container "$name" "$desc"
}

# Bring a container up and run a command in it: create or start it, stop any
# Claude already running there (when launching Claude), update Claude Code if
# it has not been checked today, record the session, then attach.
# Args: <container> <create:0|1> <description> <session-id|""> <command...>
launch() {
    local c="$1" create="$2" desc="$3" sid="$4"; shift 4
    if [ "$create" = "1" ]; then create_container "$c" "$desc"; else ensure_running "$c"; fi
    [ "$1" = "claude" ] && clear_live_claude "$c"
    maybe_update_claude "$c"
    bootstrap_container "$c"
    record_session "$c" "$sid"
    echo "Attaching to container: $c"
    docker exec -it "$c" "$@"
}

# Where a session was last run, for the picker: "open in <c>", "in <c>", or "".
session_location() {
    local c
    c=$([ -f "$STATE_FILE" ] && jq -r --arg s "$1" '.containers[]? | select(.session_id==$s) | .name' "$STATE_FILE" 2>/dev/null | head -1)
    [ -z "$c" ] && return 0
    if docker ps --format '{{.Names}}' | grep -qx "$c" && [ -n "$(claude_cli_pids "$c")" ]; then
        printf 'open in %s' "$c"
    else
        printf 'in %s' "$c"
    fi
}

# List this checkout's sessions, newest first, and let the user pick one.
# Sets PICKED_SID.
pick_session() {
    local dir="$1" files=() f i sid choice summ
    mapfile -t files < <(ls -t "$dir"/*.jsonl 2>/dev/null | head -20)
    [ ${#files[@]} -eq 0 ] && return 1
    echo ""
    echo "Sessions in ${SANDBOX_WORKDIR/#$HOME/~} (newest first):"
    for i in "${!files[@]}"; do
        f="${files[$i]}"
        sid=$(basename "$f" .jsonl)
        summ=$(summary_of_file "$f")
        printf "  %2d) %-4s %-8s  %-34s %s\n" "$((i+1))" "$(age_short "$(stat -c %Y "$f")")" \
            "${sid:0:8}" "$(session_location "$sid")" "${summ:-(no messages yet)}"
    done
    echo ""
    read -rp "Resume which? [1-${#files[@]}, Enter = 1]: " choice
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#files[@]} ]; then
        echo "Invalid selection." >&2
        exit 1
    fi
    PICKED_SID=$(basename "${files[$((choice-1))]}" .jsonl)
}

# Decide which container runs a resumed session: the one it last ran in, else
# this checkout's only sandbox, else ask (or create one if there is none).
# Sets TARGET / TARGET_CREATE / TARGET_DESC.
resolve_container() {
    local sid="$1" c cands=() legacy=() i choice d
    TARGET=""; TARGET_CREATE=0; TARGET_DESC=""

    c=$([ -f "$STATE_FILE" ] && jq -r --arg s "$sid" '.containers[]? | select(.session_id==$s) | .name' "$STATE_FILE" 2>/dev/null | head -1)
    if [ -n "$c" ] && docker ps -a --format '{{.Names}}' | grep -qx "$c" && container_matches_workdir "$c"; then
        echo "Session last ran in $c."
        TARGET="$c"; return
    fi

    while IFS= read -r c; do
        [ -z "$c" ] && continue
        if container_matches_workdir "$c"; then cands+=("$c"); else legacy+=("$c"); fi
    done < <(repo_containers)

    if [ ${#legacy[@]} -gt 0 ]; then
        echo "Note: ${legacy[*]} run(s) at /workspace (created before 1.0.3) and cannot resume"
        echo "      this checkout's sessions. Recreate with: docker rm -f <name>  (code and"
        echo "      transcripts are on the host)."
    fi

    if [ ${#cands[@]} -eq 0 ]; then
        echo "No usable sandbox for this checkout — creating one."
        prompt_new_container
        TARGET="$NEW_NAME"; TARGET_CREATE=1; TARGET_DESC="$NEW_DESC"; return
    fi
    if [ ${#cands[@]} -eq 1 ] || ! [ -t 0 ]; then
        TARGET="${cands[0]}"; return
    fi

    echo ""
    echo "Which sandbox should run it?"
    for i in "${!cands[@]}"; do
        d=$([ -f "$STATE_FILE" ] && jq -r --arg n "${cands[$i]}" '.containers[]? | select(.name==$n) | .description // empty' "$STATE_FILE" 2>/dev/null)
        printf "  %d) %-30s %s\n" "$((i+1))" "${cands[$i]}" "$(describe_container "${cands[$i]}" "$d" "")"
    done
    echo "  n) Create a new sandbox"
    read -rp "Choose [1-${#cands[@]} or n]: " choice
    if [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
        prompt_new_container
        TARGET="$NEW_NAME"; TARGET_CREATE=1; TARGET_DESC="$NEW_DESC"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#cands[@]} ]; then
        TARGET="${cands[$((choice-1))]}"
    else
        echo "Invalid selection." >&2
        exit 1
    fi
}

# --- Self-upgrade from the installed plugin ---
# sandbox.sh is copied into each repo, so a plugin release does not reach a
# repo until something re-copies it. Do that on every run: when the installed
# plugin carries a newer sandbox.sh, replace this file and re-run the same
# command with it. Never downgrades. SANDBOX_NO_AUTO_UPGRADE=1 turns it off.
auto_upgrade() {
    local plugin src new self tmp
    [ "${SANDBOX_NO_AUTO_UPGRADE:-}" = "1" ] && return 0
    [ -n "${SANDBOX_JUST_UPGRADED:-}" ] && return 0   # we are the re-run
    plugin=$(find_plugin_dir) || return 0
    src="$plugin/skills/init-sandbox/templates/sandbox.sh"
    new=$(sh_version_of "$src")
    version_lt "$SANDBOX_SH_VERSION" "$new" || return 0

    # Bash reads a script while running it, so never rewrite this file in
    # place: write a sibling and rename it over, which swaps the inode.
    self="$SCRIPT_DIR/$(basename "$0")"
    tmp=$(mktemp "$self.XXXXXX") || return 0
    if ! { cp "$src" "$tmp" && chmod 755 "$tmp"; }; then rm -f "$tmp"; return 0; fi
    cp "$self" "$self.bak-$SANDBOX_SH_VERSION" 2>/dev/null
    mv "$tmp" "$self" || { rm -f "$tmp"; return 0; }
    echo "sandbox.sh $SANDBOX_SH_VERSION → $new (from the installed plugin; previous copy kept as $(basename "$self").bak-$SANDBOX_SH_VERSION)"
    SANDBOX_JUST_UPGRADED=1 exec "$self" "$@"
}

case "$MODE" in
    version|--version|-v|help|--help|-h) ;;   # report this copy as it is
    *) auto_upgrade "$@" ;;
esac

# --- Subcommand dispatch (before the session modes) ---
case "$MODE" in
    ls|list)   shift; cmd_ls "$@"; exit $? ;;
    stop)      shift; cmd_stop "$@"; exit $? ;;
    upgrade)   shift; cmd_upgrade "$@"; exit $? ;;
    version|--version|-v) echo "sandbox.sh $SANDBOX_SH_VERSION"; exit 0 ;;
    help|--help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
        echo "Unknown mode: '$MODE'" >&2
        echo "Modes: safe | full | shell | resume | ls | stop | upgrade | version | help" >&2
        exit 2 ;;
esac

# --- Resume mode ---
# Session first: pick the conversation, then it runs in the sandbox it last ran
# in (started or created as needed), with any Claude already there stopped.
if [ "$MODE" = "resume" ]; then
    shift
    TRUST_MODE="full"; WANT_LAST=0; WANT_ID=""
    for a in "$@"; do
        case "$a" in
            safe|full) TRUST_MODE="$a" ;;
            --last|last) WANT_LAST=1 ;;
            -*) echo "Unknown option for resume: $a" >&2; exit 2 ;;
            *) WANT_ID="$a" ;;
        esac
    done

    SDIR=$(session_dir_for "$SANDBOX_WORKDIR") || SDIR=""
    SID=""
    if [ -n "$WANT_ID" ]; then
        mapfile -t matches < <(ls "$SDIR"/"$WANT_ID"*.jsonl 2>/dev/null)
        if [ ${#matches[@]} -ne 1 ]; then
            echo "Session '$WANT_ID': ${#matches[@]} matches in ${SANDBOX_WORKDIR/#$HOME/~}." >&2
            exit 1
        fi
        SID=$(basename "${matches[0]}" .jsonl)
    elif [ "$WANT_LAST" = "1" ] || ! [ -t 0 ]; then
        f=$(ls -t "$SDIR"/*.jsonl 2>/dev/null | head -1)
        [ -n "$f" ] && SID=$(basename "$f" .jsonl)
        [ -n "$SID" ] && echo "Most recent session: ${SID:0:8}  $(summary_of_file "$f")"
    else
        pick_session "$SDIR" && SID="$PICKED_SID"
    fi

    if [ -z "$SID" ]; then
        echo "No Claude sessions found for ${SANDBOX_WORKDIR/#$HOME/~}." >&2
        echo "Start one with:  ./sandbox.sh full   (or ./sandbox.sh for safe mode)" >&2
        echo "Sessions from a /workspace sandbox (pre-1.0.3) are only visible inside it:" >&2
        echo "  ./sandbox.sh shell   then   claude --resume" >&2
        exit 1
    fi

    resolve_container "$SID"
    choose_model
    if [ "$TRUST_MODE" = "safe" ]; then
        echo "Resuming in safe mode..."
        PERM_ARGS=()
        apply_profile "safe"
    else
        echo "Resuming in full trust mode..."
        PERM_ARGS=(--dangerously-skip-permissions)
        apply_profile "full"
    fi
    launch "$TARGET" "$TARGET_CREATE" "$TARGET_DESC" "$SID" \
        claude "${PERM_ARGS[@]}" --resume "$SID" "${MODEL_ARGS[@]}"
    exit $?
fi

# --- Normal modes (full / safe / shell) ---
# New sessions get an explicit --session-id so `ls`/`stop`/`resume` can tell
# which session a container is running as a recorded fact, not an inference.
NEW_SESSION_ID=""
if [ "$MODE" = "full" ]; then
    echo "WARNING: Running in full trust mode - all commands allowed"
    NEW_SESSION_ID=$(new_uuid)
    CLAUDE_CMD=(claude --dangerously-skip-permissions)
    apply_profile "full"
elif [ "$MODE" = "shell" ]; then
    echo "Opening container shell (run 'claude' to start Claude Code)"
    CLAUDE_CMD=(bash)
    apply_profile "safe"
else
    echo "Running in safe mode with restricted permissions"
    NEW_SESSION_ID=$(new_uuid)
    CLAUDE_CMD=(claude)
    apply_profile "safe"
fi
[ -n "$NEW_SESSION_ID" ] && CLAUDE_CMD+=(--session-id "$NEW_SESSION_ID")

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
    prompt_new_container
    CONTAINER_NAME="$NEW_NAME"
    CREATE_NEW=1
elif [ "$SELECTION" != "none" ] && [ "$SELECTION" != "auto" ]; then
    # User picked an existing container from the menu.
    CONTAINER_NAME="$SELECTION"
else
    # none/auto: default name — attach if it exists, otherwise create it.
    docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" || CREATE_NEW=1
fi

if [ "$MODE" != "shell" ]; then
    choose_model
    CLAUDE_CMD+=("${MODEL_ARGS[@]}")
fi

launch "$CONTAINER_NAME" "$CREATE_NEW" "$NEW_DESC" "$NEW_SESSION_ID" "${CLAUDE_CMD[@]}"
