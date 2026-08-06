# Changelog

All notable changes to this plugin are documented here. Versions follow the
`version` field in `.claude-plugin/plugin.json`, and each release is tagged
(`vX.Y.Z`) so it can be pinned.

## [1.0.5] - 2026-08-06

### Fixed
- `/init-sandbox` no longer stalls in auto/headless permission mode. The
  `full-trust.json` profile previously contained `"defaultMode":
  "bypassPermissions"`, which trips Claude Code's auto-mode safety classifier
  and blocks the file write, leaving setup incomplete. Full trust is delivered
  by the `--dangerously-skip-permissions` flag that `sandbox.sh` already passes
  on every `full`/`resume` launch, so the redundant `defaultMode` line was
  removed from the profile. Behavior is unchanged; the file now only carries the
  agent-teams env var and no restrictions.

## [1.0.4] - 2026-08-05

### Fixed
- Worktrees created **outside** the repo tree are now mounted. On first launch
  `sandbox.sh` writes a gitignored `.sandbox-worktree.override.yml` compose
  override that adds the worktree's host path, so git commands inside the
  container resolve their gitdir correctly. Standard repos and inside-tree
  worktrees are unaffected (they remain subpaths of the repo mount). This
  removes the known limitation noted in 1.0.3.
- Bumped the image to **Node.js 22** (from 20). Current Claude Code requires
  Node >= 22; on Node 20 it installed with an `EBADENGINE` warning and was one
  release from breaking. Surfaced by the end-to-end run below.

### Verified
- End-to-end: image builds with `gh` + `git-lfs`, the repo mounts at its host
  absolute path with a matching `working_dir` (session-key parity), and the
  container bootstrap wires up gh/git identity.

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

[1.0.5]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.5
[1.0.4]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.4
[1.0.3]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.3
[1.0.2]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.2
[1.0.1]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.1
[1.0.0]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.0
