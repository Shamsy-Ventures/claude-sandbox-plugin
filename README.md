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
- **Session resume**: Pick a past conversation (or `--last`); it resumes in the sandbox it last ran in, which is started or created as needed
- **One Claude per sandbox**: Claude processes left running by a dropped terminal are stopped before the next launch, so sessions can't pile up and exhaust memory
- **Model choice**: Every launch asks which model to use (Enter keeps your last choice; `SANDBOX_MODEL` skips the question)
- **GitHub CLI & git-lfs**: `gh` and `git-lfs` baked in; `gh` auth shared with the host and wired into git on every entry
- **Auto-update**: Claude Code inside each sandbox is updated at most once a day (`SANDBOX_UPDATE=1` forces it)
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
./sandbox.sh resume          # full trust: pick a session, it resumes in its sandbox
./sandbox.sh resume safe     # safe mode
./sandbox.sh resume --last   # most recent session, no picker
```

## What gets generated

- `Dockerfile.claude-sandbox` — Docker image with Python, Node.js, Claude CLI, `gh`, `git-lfs`
- `docker-compose.sandbox.yml` — Container config with volume mounts
- `sandbox.sh` — Launch script (safe/full/shell/resume modes)
- `.sandbox-state.json` — Container signature tracking (gitignored)
- `.claude/profiles/` — Permission profiles
- `.claude-plugins/` — Plugin configuration
