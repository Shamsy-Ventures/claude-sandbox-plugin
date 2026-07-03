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
| `Dockerfile.claude-sandbox` | Docker image with Python, Node.js, Claude Code CLI |
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

A git worktree's `.git` is a file that points at the main repository's `.git/worktrees/<name>` by absolute host path (and the main repo links back the same way). Mounting only the worktree at `/workspace` breaks every git command inside the container.

`/init-sandbox` detects this automatically: in a worktree it generates a compose file that mounts both the worktree and the main repository at their identical absolute host paths, and sets `working_dir` to the worktree path. Each worktree gets its own container (named after its directory), so a repo and several of its worktrees can run as parallel sandboxes.

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
