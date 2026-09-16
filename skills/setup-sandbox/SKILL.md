---
name: setup-sandbox
description: Show documentation for Claude Code sandbox setup options, customization, and session resume
disable-model-invocation: true
---

# Claude Code Sandbox Setup Guide

This skill explains how the sandbox infrastructure works and customization options.

## Quick Start

For most projects, just run `/init-sandbox` which will create all files automatically.

## What Gets Created

| File | Purpose |
|------|---------|
| `Dockerfile.claude-sandbox` | Docker image with Python, Node.js, Claude Code CLI, `gh`, and `git-lfs` |
| `docker-compose.sandbox.yml` | Container orchestration with volume mounts |
| `sandbox.sh` | Launch script with safe/full/shell/resume modes |
| `.sandbox-state.json` | Container signature tracking (gitignored) |
| `.dockerignore` | Excludes .env from image build |
| `.claude/profiles/safe-mode.json` | Restricted permissions (recommended) |
| `.claude/profiles/full-trust.json` | Unrestricted permissions |
| `.claude-plugins/` | Plugin configuration (ralph-loop pre-enabled) |

## Usage Modes

### Safe Mode (Default)
```bash
./sandbox.sh
```
- Allows common dev operations: python, pip, pytest, git, npm, node
- Blocks dangerous commands: `rm -rf`, `sudo`
- Recommended for normal development

### Full Trust Mode
```bash
./sandbox.sh full
```
- Allows all commands
- Runs with `--dangerously-skip-permissions`
- Use only when you need unrestricted access

### Attach-or-create picker (multiple sandboxes per project)

When you run `full`/`safe`/`shell` in an interactive terminal **and at least one sandbox already exists** for the project, `sandbox.sh` shows a picker instead of silently attaching to the default container:

```
Sandboxes for myproject:
  1) myproject-sandbox      [Up 3 hours]              running claude ~"Auth refactor" · main dev
  2) myproject-exp          [Exited (0) 2 days ago]   idle · spike: new parser
  n) Create a new sandbox

Attach to [1-2] or 'n' for new:
```

Each row shows the container status, what's live inside it (`running claude` / `running codex` / `shell open` / `idle`), a **best-effort** guess of the current Claude session topic (the `~"..."` part — a repo-wide hint, not guaranteed to be that exact container's session), and the **description** you gave the container when you created it.

- Pick a number → attach to that container (starting it if stopped).
- Pick `n` → you're prompted for a **name** (defaults to the next free `<project>-sandbox-N`) and a short **description**, then a fresh container is created. Each new sandbox is its own compose project, so several can run in parallel against the same repo.

The picker only appears once a container exists — the very first `./sandbox.sh full` in a project just creates the default `<project>-sandbox`. In non-interactive/CI contexts (no TTY) the picker is skipped entirely and the default container is used, so nothing hangs.

### Shell Mode
```bash
./sandbox.sh shell
```
- Opens a bash shell in the container without starting Claude
- Run `claude` or `claude --dangerously-skip-permissions` manually when ready
- Useful for setup, inspection, or running commands before starting Claude

### Resume Mode
```bash
./sandbox.sh resume        # full trust (default)
./sandbox.sh resume safe   # safe mode
```
- Reads `.sandbox-state.json` to find containers belonging to this project
- If multiple containers exist, presents an interactive picker with status
- If only one exists, auto-selects it
- Starts the container if stopped, then runs `claude --resume` for interactive session picker
- Falls back to scanning docker by project name if no state file exists

## Session Carry-Over (Same-Path Mounting)

Claude Code keys each session by the absolute working directory: `~/.claude/projects/<encoded-cwd>`. The repo is mounted **at its host absolute path** inside the container (not at `/workspace`), and `~/.claude` is shared with the host, so those keys are identical on the host, in every container, and across worktrees. A session started on the host is resumable in any sandbox, and vice versa.

`sandbox.sh` computes the paths at launch and exports them for compose:
- `SANDBOX_REPO_ROOT` — the main repo root (`git rev-parse --git-common-dir`), mounted at the same path
- `SANDBOX_WORKDIR` — the launch directory (the worktree when launched from one), used as `working_dir`
- `SANDBOX_CONTAINER_NAME` — the target container name (default `<project>-sandbox`, or the name you choose when creating an additional sandbox)

The `:-` defaults in the compose file keep a plain `docker compose` invocation working at `/workspace` when the script isn't used.

## GitHub CLI & git

The image bundles `gh` and `git-lfs`. On every entry, `sandbox.sh` bootstraps the container (idempotent):
- `gh auth setup-git` so git push/pull over HTTPS uses your gh credentials
- `git lfs install`
- copies the host's `git config user.name`/`user.email` into the container

`gh` auth is shared with the host via the `~/.config/gh` mount, so `gh auth login` once — on the host or in any container — and every sandbox stays authenticated. Alternatively set `GH_TOKEN` in the environment. If `gh` is unauthenticated, the bootstrap prints a one-time hint.

## Auto-Update on Entry

Every time `sandbox.sh` enters a container — newly created, restarted, or already running, in any mode (default/`full`/`shell`/`resume`) — it updates Claude Code to the latest version before launching:

```bash
docker exec -u root <container> npm install -g @anthropic-ai/claude-code@latest
```

It runs as root because the CLI lives in the root-owned npm global directory inside the image. If the update fails (e.g. no network), a warning is printed and the existing installed version is used.

New containers are created detached (`docker compose up -d`), updated, and then attached — so even if the Docker image was built from a cached layer with an older CLI, the container gets the latest version before Claude first starts.

## Lifecycle: ls / stop / reap

Sandboxes used to only ever be created or attached to — nothing in the plugin
stopped one. Containers therefore accumulated until the host ran out of memory.
These three commands close that loop.

**Stopping a sandbox is non-destructive.** The repo and `~/.claude` are
bind-mounted from the host, so your code and every session transcript live
*outside* the container. `docker start`, or any launch mode, resumes exactly
where you left off. Only `docker rm` discards anything, and even then it is just
the container layer (packages installed inside it, its shell history).

### `./sandbox.sh ls [--all]`

Lists this repo's sandboxes, or every sandbox on the host with `--all`:

```
  CONTAINER                    STATUS        TOOL    SESSION    TOPIC                     IDLE
  hubtrack-sandbox             Up 2 months   claude  ?shared    -                         68d
  hubtrack-sandbox-pr-reviews  Up 2 weeks    claude  ~6764e752  "What are the pr-review…"  5m
  vanilla-agent-sandbox        Up 5 weeks    claude  399d7896   "go through the context…" 2m
```

- **TOOL** — what is actually running inside: `claude`, `codex`, `shell`, `-`.
- **SESSION** — the Claude session id. Bare (`399d7896`) means sandbox.sh
  launched it with an explicit `--session-id` and recorded it, so the mapping is
  a fact. `~` means it was inferred from transcript timestamps. `?shared` means
  several live sandboxes write to one transcript directory and the session
  genuinely cannot be told apart — see below.
- **TOPIC** — the newest rollup summary Claude wrote for that session, falling
  back to the description you typed when creating the sandbox.
- **IDLE** — time since that session's transcript was last written. This is the
  real activity clock, not container uptime.

### `./sandbox.sh stop [--all]`

Shows the same table, numbered, and asks which to stop. Accepts `1 3 5`,
`2-4`, `1,3`, `all`, or `q` to cancel. Before acting it restates each selection
with its session id and topic, and flags any with a live Claude session:

```
Will stop:
  - crypto-bot-sandbox   session 8a1f20c3  "Backtest the momentum strategy"   [LIVE claude — will be interrupted]

Confirm stop? [y/N]:
```

A live session is safe to interrupt — the transcript is already on the host, so
`./sandbox.sh resume` (or `claude --resume <id>`) picks it back up.

### `./sandbox.sh reap [--days N] [--dry-run] [--yes]`

Host-wide. Stops every running sandbox whose session transcript has not been
written in `N` days (default 7). `--dry-run` reports without acting; `--yes`
skips the prompt so it can run from a systemd timer or cron. Without a TTY and
without `--yes` it refuses rather than stopping things unattended.

### Why a session can be `?shared`

Claude Code keys transcripts by absolute cwd. Two sandboxes end up sharing one
transcript directory when they serve the same repo, or — for containers built
from a pre-1.0.3 compose file — when they each mount their repo at `/workspace`,
which collapses every such project into one `~/.claude/projects/-workspace`
bucket. When more than one *live* container claims a directory, `ls` reports
`?shared` instead of naming a session at random, and falls back to container
start time for the idle clock so a dormant sandbox cannot inherit a sibling's
freshness. Sessions started by v1.0.7+ record their id at launch and are never
ambiguous, so this clears itself as you restart sandboxes.

## Keeping sandbox.sh current across repos

`sandbox.sh` is generated *into* each repo, so upgrading the plugin does not
update repos created earlier — they keep running whatever version they were
scaffolded with.

**In one repo:** `./sandbox.sh upgrade` re-copies the canonical template from
the installed plugin, keeping a `sandbox.sh.bak-<oldversion>`.

**Across every repo:** run the plugin's standalone propagation script:

```bash
bash ~/.claude/plugins/cache/*/claude-sandbox/*/skills/init-sandbox/templates/sync-sandboxes.sh --dry-run
bash ~/.claude/plugins/cache/*/claude-sandbox/*/skills/init-sandbox/templates/sync-sandboxes.sh
```

It finds every `sandbox.sh` under `$HOME`, reports its version, and refreshes
the stale ones. It never touches a container.

This is deliberately a separate script rather than only a `sandbox.sh`
subcommand: `./sandbox.sh upgrade` only works if that copy already knows the
verb. Older copies fall through to their default mode and **build a container**
instead — the opposite of an upgrade. Propagation has to come from the plugin
side. (v1.0.7 also makes an unrecognised mode a hard error, so that failure
cannot recur from here on.)

`sync-sandboxes.sh` additionally reports **compose drift** — repos whose
`docker-compose.sandbox.yml` predates v1.0.3 and still mounts at `/workspace`.
It will not fix those itself: the compose file must be regenerated with
`/init-sandbox` and the container recreated, which changes the session key. Do
that per repo when you next work in it.

## Container Tracking

When you first create a container (`./sandbox.sh full` or `./sandbox.sh`), the script records its signature in `.sandbox-state.json`:

```json
{
  "containers": [
    {
      "name": "my-project-sandbox",
      "id": "a1b2c3d4e5f6",
      "image": "my-project-claude-sandbox",
      "created_at": "2026-06-03T12:00:00Z",
      "description": "main dev"
    }
  ]
}
```

The `description` is what you typed when the container was created; it's shown in the attach-or-create picker so you can tell your sandboxes apart.

This file is gitignored (container IDs are machine-specific) but stays in the repo directory so you can quickly find your containers on resume.

## Customization

### Change Base Language

Edit `Dockerfile.claude-sandbox` first line:
- Python: `FROM python:3.11-slim`
- Node: `FROM node:22-slim`
- Go: `FROM golang:1.21-bookworm`
- Rust: `FROM rust:1.75-slim-bookworm`

### Add More Plugins

Edit `.claude-plugins/settings.json`:
```json
{
  "enabledPlugins": {
    "ralph-loop@claude-plugins-official": true,
    "another-plugin@marketplace": true
  }
}
```

### Modify Permissions

Edit `.claude/profiles/safe-mode.json` to add/remove allowed commands:
```json
{
  "permissions": {
    "allow": [
      "Bash(your-command:*)"
    ]
  }
}
```

### Resource Limits

Defaults are 1.5G memory / 1.5 CPUs per container, sized so several sandboxes can run in parallel on a small host. Edit `docker-compose.sandbox.yml` to raise them:
```yaml
deploy:
  resources:
    limits:
      memory: 8G  # Increase memory
      cpus: '4'   # More CPU cores
```

## Git Worktrees

A git worktree's `.git` is a file that points at the main repository's `.git/worktrees/<name>` by absolute host path (and the main repo links back the same way). The container must therefore see the main repo at that same path.

Same-path mounting handles this with no separate template: when launched from a worktree, `sandbox.sh` resolves the main repo via `git rev-parse --git-common-dir`, mounts it at its host path (`SANDBOX_REPO_ROOT`), and sets `working_dir` to the worktree (`SANDBOX_WORKDIR`). A worktree created **inside** the repo tree (e.g. `git worktree add .claude/worktrees/feature`) is a subpath of that mount, so it — and its Claude session — carries over automatically. A worktree created **outside** the repo tree is mounted as well: on first launch `sandbox.sh` writes a gitignored `.sandbox-worktree.override.yml` compose override that adds the worktree's host path. Each worktree gets its own container (named after its directory), so a repo and several of its worktrees can run as parallel sandboxes.

## Environment Variables

Set your API key before running:
```bash
export ANTHROPIC_API_KEY=your-key-here
```

Add any other environment variables your project needs to `docker-compose.sandbox.yml` under the `environment` section.

## Troubleshooting

**Container won't start:**
```bash
docker compose -f docker-compose.sandbox.yml build --no-cache
```

**Plugin not working:**
Ensure plugin cache is mounted:
```bash
ls ~/.claude/plugins/cache/
```

**Permission denied:**
```bash
chmod +x sandbox.sh
```

**Can't find container on resume:**
Check `.sandbox-state.json` exists and the container hasn't been removed:
```bash
cat .sandbox-state.json
docker ps -a
```
