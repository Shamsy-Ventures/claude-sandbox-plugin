# Changelog

All notable changes to this plugin are documented here. Versions follow the
`version` field in `.claude-plugin/plugin.json`, and each release is tagged
(`vX.Y.Z`) so it can be pinned.

## [1.0.3] - 2026-07-09

### Added
- **Same-path repo mounting** — the repo is mounted at its host absolute path
  (not `/workspace`) so Claude Code session keys
  (`~/.claude/projects/<encoded-cwd>`) match between host, container, and
  worktrees. A session started anywhere is resumable everywhere.
- `gh` (GitHub CLI) and `git-lfs` baked into the sandbox image; `~/.config/gh`
  shared with the host and `GH_TOKEN` passthrough so `gh auth login` persists
  across all containers.
- `bootstrap_container` runs on every entry (idempotent): `gh auth setup-git`,
  `git lfs install`, and copies the host's git identity into the container.

### Changed
- Unified the two `docker-compose` templates (standard + git-worktree) into a
  single template; `sandbox.sh` now resolves paths at launch (worktree-aware via
  `git rev-parse --git-common-dir`) and exports `SANDBOX_REPO_ROOT` /
  `SANDBOX_WORKDIR` / `SANDBOX_CONTAINER_NAME`. The `:-` defaults keep a plain
  `docker compose` invocation working at `/workspace`.

### Known limitations
- Worktrees created **outside** the repo tree (e.g. `git worktree add ../x`) are
  not mounted, since only the main repo root is mounted at its host path.
  Worktrees created **inside** the repo tree carry over automatically.

## [1.0.2] - 2026-07-09

### Changed
- Right-sized container resource limits (1.5G memory / 1.5 CPUs) so several
  sandboxes can run in parallel on a small host.
- Added a git-worktree `docker-compose` variant that mounts both the worktree
  and the main repository at their absolute host paths.

## [1.0.1]

### Changed
- Version bump.

## [1.0.0]

### Added
- Initial release: `init-sandbox` and `setup-sandbox` skills.
- Docker-based sandbox generation (`Dockerfile.claude-sandbox`,
  `docker-compose.sandbox.yml`, `sandbox.sh`).
- Safe-mode and full-trust permission profiles.
- Container tracking in `.sandbox-state.json` and interactive session resume.
- Claude Code auto-update on container entry.
- Embedded `sandbox.sh` fallback for restricted sessions.
- Marketplace manifest for installation via `/plugin marketplace add`.

[1.0.3]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.3
[1.0.2]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.2
[1.0.1]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.1
[1.0.0]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.0
