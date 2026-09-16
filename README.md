# claude-sandbox

A Claude Code plugin that sets up Docker-based sandboxes with permission profiles, container tracking, and session resume.

## Skills

| Skill | Description |
|-------|-------------|
| `/claude-sandbox:init-sandbox` | Generate all sandbox files for the current project |
| `/claude-sandbox:setup-sandbox` | View documentation and customization options |

## Features

- **Permission profiles**: Safe mode (restricted) and full trust mode
- **Container tracking**: Records container name/ID/description in `.sandbox-state.json` so you can find them later
- **Attach-or-create picker**: When a sandbox already exists, choose whether to attach to it (with a description of what's running there) or create a new, named one — multiple sandboxes can run against one repo
- **Session carry-over**: The repo is mounted at its host absolute path, so a Claude session started on the host, in any container, or in a worktree resumes anywhere
- **Session resume**: Pick a container interactively, then pick a Claude session to resume
- **GitHub CLI & git-lfs**: `gh` and `git-lfs` baked in; `gh` auth shared with the host and wired into git on every entry
- **Auto-update**: Claude Code is updated to the latest version every time a container is created or re-entered
- **Plugin support**: Pre-configures ralph-loop plugin inside the container

## Install

### As a plugin (recommended for cross-machine use)

```bash
# In Claude Code, add this repo as a marketplace:
/plugin marketplace add Shamsy-Ventures/claude-sandbox-plugin

# Install:
/plugin install claude-sandbox@rshamsy-claude-sandbox-plugin --scope user
```

### As standalone skills (single machine)

Copy the skills into your user-level skills directory:

```bash
cp -r skills/init-sandbox ~/.claude/skills/
cp -r skills/setup-sandbox ~/.claude/skills/
```

## Usage

1. Navigate to any project directory
2. Run `/init-sandbox` (or `/claude-sandbox:init-sandbox` if installed as plugin)
3. Set your `ANTHROPIC_API_KEY` environment variable
4. Run `./sandbox.sh full` to start

### Resume a previous session

```bash
./sandbox.sh resume        # full trust, interactive container + session picker
./sandbox.sh resume safe   # safe mode
```

## What gets generated

- `Dockerfile.claude-sandbox` — Docker image with Python, Node.js, Claude CLI, `gh`, `git-lfs`
- `docker-compose.sandbox.yml` — Container config with volume mounts
- `sandbox.sh` — Launch script (safe/full/shell/resume modes)
- `.sandbox-state.json` — Container signature tracking (gitignored)
- `.claude/profiles/` — Permission profiles
- `.claude-plugins/` — Plugin configuration
