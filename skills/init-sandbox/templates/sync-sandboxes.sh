#!/bin/bash
# Propagate the canonical sandbox.sh to every repo that has one.
#
# Usage:
#   sync-sandboxes.sh [--dry-run] [--root DIR] [--force] [--quiet]
#
#   --dry-run   Report what would change; write nothing.
#   --root DIR  Where to search for repos (default: $HOME).
#   --force     Re-copy even when the version already matches.
#   --quiet     Only print repos that changed (for cron / timers).
#
# Why this exists as a standalone script rather than a sandbox.sh subcommand:
# `./sandbox.sh upgrade` only works if that copy is already new enough to know
# the verb. Older copies fall through to their default mode and *build a
# container* instead — the opposite of an upgrade. Propagation therefore has to
# be driven from the plugin side, by a script that makes no assumption about
# what is already installed in the repo.
#
# This script never creates, starts, stops or removes a container. It only
# rewrites sandbox.sh (keeping a .bak-<oldversion>) and reports drift it cannot
# safely fix on its own.

set -uo pipefail

DRY=0
FORCE=""
QUIET=0
ROOT="$HOME"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) DRY=1; shift ;;
        --force)      FORCE=1; shift ;;
        --quiet|-q)   QUIET=1; shift ;;
        --root)       ROOT="$2"; shift 2 ;;
        --root=*)     ROOT="${1#*=}"; shift ;;
        -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Locate the canonical template -------------------------------------------
# Prefer the copy sitting next to this script (we ship together), then an
# explicit override, then the highest installed plugin version.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC=""
if [ -f "$SELF_DIR/sandbox.sh" ]; then
    SRC="$SELF_DIR/sandbox.sh"
elif [ -n "${CLAUDE_SANDBOX_PLUGIN_DIR:-}" ] && [ -f "$CLAUDE_SANDBOX_PLUGIN_DIR/skills/init-sandbox/templates/sandbox.sh" ]; then
    SRC="$CLAUDE_SANDBOX_PLUGIN_DIR/skills/init-sandbox/templates/sandbox.sh"
else
    c=$(ls -d "$HOME"/.claude/plugins/cache/*/claude-sandbox/*/ 2>/dev/null | sort -V | tail -1)
    [ -n "$c" ] && [ -f "${c}skills/init-sandbox/templates/sandbox.sh" ] && \
        SRC="${c}skills/init-sandbox/templates/sandbox.sh"
fi
[ -n "$SRC" ] && [ -f "$SRC" ] || {
    echo "Error: could not find the canonical sandbox.sh template." >&2
    echo "Set CLAUDE_SANDBOX_PLUGIN_DIR to the plugin root and retry." >&2
    exit 1
}

version_of() {
    local v
    v=$(grep -m1 '^SANDBOX_SH_VERSION=' "$1" 2>/dev/null | cut -d'"' -f2)
    printf '%s' "${v:-1.0.0}"
}

NEW_VER=$(version_of "$SRC")
SRC_REAL=$(readlink -f "$SRC")

echo "Canonical template : $SRC  (v$NEW_VER)"
echo "Search root        : $ROOT"
[ "$DRY" = "1" ] && echo "Mode               : DRY RUN (nothing will be written)"
echo ""

# --- Find every repo carrying a sandbox.sh ------------------------------------
mapfile -t REPOS < <(
    find "$ROOT" -maxdepth 5 -name sandbox.sh -type f \
        -not -path "*/node_modules/*" -not -path "*/.git/*" \
        -printf '%h\n' 2>/dev/null | sort -u
)

if [ ${#REPOS[@]} -eq 0 ]; then
    echo "No repos with a sandbox.sh found under $ROOT."
    exit 0
fi

upgraded=0; current=0; skipped=0
declare -a DRIFT=()

for repo in "${REPOS[@]}"; do
    dst="$repo/sandbox.sh"
    # Never rewrite the template we are copying from.
    [ "$(readlink -f "$dst")" = "$SRC_REAL" ] && { skipped=$((skipped+1)); continue; }

    cur=$(version_of "$dst")
    short="${repo/#$HOME/~}"

    # Compose files predating v1.0.3 mount the repo at /workspace, which makes
    # every such repo share one Claude transcript directory. Rewriting
    # sandbox.sh does not fix that — the compose file must be regenerated and
    # the container recreated, which changes the session key. Report, never do.
    compose="$repo/docker-compose.sandbox.yml"
    if [ -f "$compose" ] && ! grep -q 'SANDBOX_REPO_ROOT' "$compose" 2>/dev/null; then
        DRIFT+=("$short")
    fi

    if [ "$cur" = "$NEW_VER" ] && [ -z "$FORCE" ]; then
        current=$((current+1))
        [ "$QUIET" = "1" ] || printf "  %-52s current (v%s)\n" "$short" "$cur"
        continue
    fi

    if [ "$DRY" = "1" ]; then
        printf "  %-52s would upgrade v%s -> v%s\n" "$short" "$cur" "$NEW_VER"
        upgraded=$((upgraded+1))
        continue
    fi

    if cp "$dst" "$dst.bak-$cur" 2>/dev/null && cp "$SRC" "$dst" 2>/dev/null; then
        chmod +x "$dst"
        printf "  %-52s upgraded v%s -> v%s\n" "$short" "$cur" "$NEW_VER"
        upgraded=$((upgraded+1))
    else
        printf "  %-52s FAILED (permissions?)\n" "$short" >&2
        skipped=$((skipped+1))
    fi
done

echo ""
echo "Summary: $upgraded upgraded, $current already current, $skipped skipped."

if [ ${#DRIFT[@]} -gt 0 ]; then
    echo ""
    echo "Compose drift — these repos still mount at /workspace (pre-1.0.3):"
    printf '    %s\n' "${DRIFT[@]}"
    echo ""
    echo "  Their sandbox.sh is now current, but until the compose file is"
    echo "  regenerated they keep sharing one ~/.claude/projects/-workspace"
    echo "  directory, so their sessions cannot be told apart. To fix one:"
    echo ""
    echo "    cd <repo> && /init-sandbox          # regenerates the compose file"
    echo "    docker rm -f <container>            # discards the container layer only"
    echo "    ./sandbox.sh full                   # recreates it at the host path"
    echo ""
    echo "  Code and transcripts are bind-mounted from the host and are not"
    echo "  affected. Do this per repo, when you next work in it — there is no"
    echo "  need to do them all at once."
fi
