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
- `SANDBOX_CONTAINER_NAME` — `<project>-sandbox`

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

## Container Tracking

When you first create a container (`./sandbox.sh full` or `./sandbox.sh`), the script records its signature in `.sandbox-state.json`:

```json
{
  "containers": [
    {
      "name": "my-project-sandbox",
      "id": "a1b2c3d4e5f6",
      "image": "my-project-claude-sandbox",
      "created_at": "2026-06-03T12:00:00Z"
    }
  ]
}
```

This file is gitignored (container IDs are machine-specific) but stays in the repo directory so you can quickly find your containers on resume.

## Customization

### Change Base Language

Edit `Dockerfile.claude-sandbox` first line:
- Python: `FROM python:3.11-slim`
- Node: `FROM node:20-slim`
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

Same-path mounting handles this with no separate template: when launched from a worktree, `sandbox.sh` resolves the main repo via `git rev-parse --git-common-dir`, mounts it at its host path (`SANDBOX_REPO_ROOT`), and sets `working_dir` to the worktree (`SANDBOX_WORKDIR`). A worktree created **inside** the repo tree (e.g. `git worktree add .claude/worktrees/feature`) is a subpath of that mount, so it — and its Claude session — carries over automatically. Each worktree gets its own container (named after its directory), so a repo and several of its worktrees can run as parallel sandboxes.

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
