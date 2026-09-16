#!/bin/bash
# Launch and manage Claude Code Docker sandboxes
#
# Session modes:
#   ./sandbox.sh              - New session in safe mode
#   ./sandbox.sh full         - New session in full trust mode
#   ./sandbox.sh shell        - Open container shell
#   ./sandbox.sh resume       - Resume: pick container + session interactively (full trust)
#   ./sandbox.sh resume safe  - Resume: pick container + session interactively (safe mode)
#
# Lifecycle:
#   ./sandbox.sh ls [--all]        - List sandboxes for this repo (--all: host-wide)
#   ./sandbox.sh stop [--all]      - Pick sandboxes to stop (multi-select)
#   ./sandbox.sh reap [--days N]   - Stop sandboxes idle past a threshold (host-wide)
#   ./sandbox.sh upgrade [--all]   - Refresh sandbox.sh from the installed plugin
#   ./sandbox.sh version           - Print this script's version
#
# Stopping a sandbox is non-destructive: the repo and ~/.claude are bind-mounted
# from the host, so code and session transcripts live outside the container.
# `docker start` (or any launch mode) picks up exactly where you left off.
#
# When a sandbox already exists for this project and you run full/safe/shell in
# an interactive terminal, you get a picker: attach to an existing container
# (showing what's running there + its description) or create a new, named one.
# With no existing container, or when non-interactive, it uses the default
# <project>-sandbox container.

SANDBOX_SH_VERSION="1.0.8"

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
    s=$(jq -rs '[.[] | select(.type=="summary") | .summary] | last // empty' "$f" 2>/dev/null)
    if [ -z "$s" ]; then
        # No rollup summary yet — fall back to the first real user message,
        # skipping the synthetic blocks Claude injects (slash-command echoes,
        # caveat preambles, hook output) which otherwise read as gibberish.
        s=$(jq -rs 'first(.[] | select(.type=="user")
                    | .message.content
                    | if type=="array" then (map(select(.type=="text").text) | join(" ")) else tostring end
                    | select(test("^<(local-command|command-name|command-message|system-reminder)") | not))
                    // empty' "$f" 2>/dev/null)
    fi
    [ -n "$s" ] && printf '%s' "$s" \
        | sed -e 's/<[^>]*>//g' -e 's/^[[:space:]]*//' \
        | tr '\n\t' '  ' | tr -s ' ' | cut -c1-58
}

# Host PID of the claude process running inside a container, if any.
# `docker top` reports host PIDs, so /proc/<pid>/... is readable from here.
container_claude_pid() {
    docker top "$1" -eo pid,args 2>/dev/null | tail -n +2 \
        | awk '{pid=$1; $1=""; if ($0 ~ /claude/ && $0 !~ /npm (install|i) / && $0 !~ /claude-code@/) {print pid; exit}}'
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
    entries=$(echo "$entries" | jq \
        --arg n "$name" --arg s "$sid" --arg t "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '[.[] | if .name == $n then . + {session_id: $s, session_started_at: $t} else . end]')
    jq -n --argjson c "$entries" '{containers: $c}' > "$STATE_FILE"
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
    # `docker top` rejects a format without a PID column ("Couldn't find PID
    # field in ps output"), so ask for pid,args and drop the pid.
    args=$(docker top "$c" -eo pid,args 2>/dev/null | tail -n +2 | cut -d' ' -f2-)
    if echo "$args" | grep -qiE 'claude-code|@anthropic-ai/claude|(^|/| )claude( |$)'; then
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
# Lifecycle subcommands: ls / stop / reap / upgrade
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
    build_claims "${ROW_NAMES[@]}"
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

    local ambiguous=0
    for i in "${!ROW_NAMES[@]}"; do
        n="${ROW_NAMES[$i]}"; st="${ROW_STATUS[$i]}"
        tool=$(running_tool "$n"); [ -z "$tool" ] && tool="-"
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
        echo "Error: 'stop' is interactive and needs a terminal. Use 'reap --yes' for automation." >&2
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

cmd_reap() {
    local days=7 dry=0 assume_yes=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --days) days="$2"; shift 2 ;;
            --days=*) days="${1#*=}"; shift ;;
            --dry-run|-n) dry=1; shift ;;
            --yes|-y) assume_yes=1; shift ;;
            *) echo "Unknown option for reap: $1" >&2; exit 1 ;;
        esac
    done
    [[ "$days" =~ ^[0-9]+$ ]] || { echo "--days needs a number" >&2; exit 1; }

    local cutoff now n st last idle_days tool targets=() running=()
    now=$(date +%s)
    cutoff=$(( now - days * 86400 ))

    while IFS= read -r n; do
        [ -z "$n" ] && continue
        docker ps --format '{{.Names}}' | grep -q "^${n}$" || continue   # already stopped
        running+=("$n")
    done < <(enumerate_sandboxes "all")
    [ ${#running[@]} -eq 0 ] && { echo "No running sandboxes."; exit 0; }

    # Claimant counts matter here: without them a dormant sandbox sharing a
    # transcript directory inherits a sibling's fresh mtime and never gets reaped.
    build_claims "${running[@]}"

    for n in "${running[@]}"; do
        last=$(last_activity_epoch "$n" "${CLAIMS_BY_NAME[$n]:-1}")
        [ "$last" = "0" ] && continue
        [ "$last" -lt "$cutoff" ] && targets+=("$n")
    done

    if [ ${#targets[@]} -eq 0 ]; then
        echo "Nothing to reap: no running sandbox has been idle longer than ${days}d."
        exit 0
    fi

    echo ""
    echo "Idle longer than ${days}d:"
    local sid summ kind cl
    for n in "${targets[@]}"; do
        cl="${CLAIMS_BY_NAME[$n]:-1}"
        tool=$(running_tool "$n"); [ -z "$tool" ] && tool="idle"
        IFS=$'\x1f' read -r sid summ kind <<< "$(container_session "$n" "$cl")"
        [ "$kind" = "ambiguous" ] && sid="?shared"
        printf "  %-34s  %-7s  %-9s  idle %-5s %s\n" \
            "$n" "$tool" "${sid:0:8}" "$(age_short "$(last_activity_epoch "$n" "$cl")")" "${summ:+\"$summ\"}"
    done
    echo ""

    if [ "$dry" = "1" ]; then
        echo "(dry run — nothing stopped)"
        exit 0
    fi

    if [ "$assume_yes" != "1" ]; then
        if ! [ -t 0 ]; then
            echo "Refusing to stop without confirmation in a non-interactive shell. Pass --yes." >&2
            exit 1
        fi
        read -rp "Stop these ${#targets[@]} sandbox(es)? [y/N]: " ok
        case "$ok" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
    fi

    for n in "${targets[@]}"; do
        docker stop "$n" >/dev/null && echo "  stopped  $n"
    done
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

# --- Subcommand dispatch (before the session modes) ---
case "$MODE" in
    ls|list)   shift; cmd_ls "$@"; exit $? ;;
    stop)      shift; cmd_stop "$@"; exit $? ;;
    reap)      shift; cmd_reap "$@"; exit $? ;;
    upgrade)   shift; cmd_upgrade "$@"; exit $? ;;
    version|--version|-v) echo "sandbox.sh $SANDBOX_SH_VERSION"; exit 0 ;;
    help|--help|-h) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    safe|full|shell|resume) ;;
    *)
        # Anything else is a typo or a subcommand this copy is too old to know.
        # Earlier versions fell through to safe mode here and *built a container*
        # — so an unrecognised verb silently did the opposite of what was asked.
        echo "Unknown mode: '$MODE'" >&2
        echo "Modes: safe | full | shell | resume | ls | stop | reap | upgrade | version | help" >&2
        exit 2 ;;
esac

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
# New sessions get an explicit --session-id so `ls`/`stop` can report which
# session a container is running as a recorded fact rather than an inference.
NEW_SESSION_ID=""
if [ "$MODE" = "full" ]; then
    echo "WARNING: Running in full trust mode - all commands allowed"
    NEW_SESSION_ID=$(new_uuid)
    CLAUDE_CMD="claude --dangerously-skip-permissions"
    [ -n "$NEW_SESSION_ID" ] && CLAUDE_CMD="$CLAUDE_CMD --session-id $NEW_SESSION_ID"
    apply_profile "full"
elif [ "$MODE" = "shell" ]; then
    echo "Opening container shell (run 'claude' to start Claude Code)"
    CLAUDE_CMD="bash"
    apply_profile "safe"
else
    echo "Running in safe mode with restricted permissions"
    NEW_SESSION_ID=$(new_uuid)
    CLAUDE_CMD="claude"
    [ -n "$NEW_SESSION_ID" ] && CLAUDE_CMD="$CLAUDE_CMD --session-id $NEW_SESSION_ID"
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
    record_session "$CONTAINER_NAME" "$NEW_SESSION_ID"
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
    record_session "$CONTAINER_NAME" "$NEW_SESSION_ID"

    docker exec -it "$CONTAINER_NAME" $CLAUDE_CMD
fi
