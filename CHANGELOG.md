# Changelog

All notable changes to this plugin are documented here. Versions follow the
`version` field in `.claude-plugin/plugin.json`, and each release is tagged
(`vX.Y.Z`) so it can be pinned.

## [1.0.8] - 2026-09-16

### Fixed
- **`upgrade` / `sync-sandboxes.sh` could silently downgrade a repo.** Both
  compared the template and repo versions only for equality, so when the plugin
  copy was *older* than the repo's script it overwrote it anyway. That is the
  normal state right after a release: the tag is pushed but the plugin cache
  still holds the previous version, so running `./sandbox.sh upgrade` would
  revert a freshly propagated repo. Both now refuse to move a repo backwards
  and say so; `--force` still overrides.

## [1.0.7] - 2026-09-16

### Added
- **Lifecycle commands.** `sandbox.sh` could only ever create or attach to a
  container — nothing in the plugin stopped one, so sandboxes accumulated until
  the host ran out of memory. Three commands close that loop:
  - `./sandbox.sh ls [--all]` — sandboxes for this repo, or every sandbox on the
    host, with what is running inside, the Claude session id and topic, and how
    long that session has really been idle.
  - `./sandbox.sh stop [--all]` — the same table, numbered, with multi-select
    (`1 3 5`, `2-4`, `all`). Restates each selection with its session id and
    topic and flags live Claude sessions before asking to confirm.
  - `./sandbox.sh reap [--days N] [--dry-run] [--yes]` — host-wide, stops
    sandboxes whose transcript has not been written in N days (default 7).
    `--yes` makes it usable from a systemd timer; without a TTY and without
    `--yes` it refuses rather than acting unattended.
- **Recorded session ids.** New `full`/`safe` sessions are launched with an
  explicit `--session-id` and the id is stored in `.sandbox-state.json`, so
  `ls`/`stop` can name the session a container is running as a recorded fact
  rather than inferring it from file timestamps.
- **`./sandbox.sh upgrade [--all]`** — re-copies the canonical template from the
  installed plugin, keeping a `sandbox.sh.bak-<oldversion>`.
- **`templates/sync-sandboxes.sh`** — standalone propagation script that finds
  every `sandbox.sh` under `$HOME` and refreshes the stale ones. It exists
  separately from `upgrade` because `./sandbox.sh upgrade` only works on a copy
  that already knows the verb; older copies fall through to their default mode
  and *build a container* instead. It never touches a container, and reports
  (without fixing) repos whose compose file still mounts at `/workspace`.

### Fixed
- **`running_tool()` never detected anything.** It called
  `docker top <c> -eo args`, which Docker rejects with "Couldn't find PID field
  in ps output" — the error was swallowed, so the function always returned
  empty. Every row of the v1.0.6 attach-or-create picker therefore showed "idle"
  no matter what was running inside. Now uses `-eo pid,args` and drops the pid.
- **An unrecognised mode built a container.** Any argument that was not
  `full`/`shell`/`resume` fell through to safe mode and created a sandbox — so a
  typo, or a subcommand an older copy did not know (`./sandbox.sh upgrade` on a
  1.0.0 script), silently did the opposite of what was asked. Unknown modes are
  now a hard error listing the valid ones.
- Session topics no longer render Claude's synthetic preambles
  (`<local-command-caveat>`, slash-command echoes) as the summary.

### Notes
- Stopping a sandbox is non-destructive and always was: the repo and `~/.claude`
  are bind-mounted from the host, so code and transcripts live outside the
  container. This release documents that guarantee and builds the commands
  around it.
- Where several *live* sandboxes share one transcript directory — two sandboxes
  on one repo, or several pre-1.0.3 containers all mounted at `/workspace` —
  `ls` reports the session as `?shared` rather than naming one at random, and
  uses container start time for the idle clock so a dormant sandbox cannot
  inherit a sibling's freshness. Sessions started by 1.0.7+ are never ambiguous.
- `SANDBOX_SH_VERSION` is now stamped in the script, so drift across repos can
  be detected exactly instead of inferred from file length.

## [1.0.6] - 2026-08-29

### Added
- **Attach-or-create picker.** Running `full`/`safe`/`shell` in an interactive
  terminal, once at least one sandbox exists for the project, now shows a menu:
  attach to an existing container or create a new, named one — instead of
  silently attaching to the default. Each row shows the container status, what's
  running inside (`claude`/`codex`/`shell`/`idle`), a best-effort guess of the
  current Claude session topic, and the description you gave it.
- **Named multiple sandboxes per repo.** Creating a new sandbox prompts for a
  name (default `<project>-sandbox-N`) and a short description. Each container
  runs as its own compose project (`-p`), so several sandboxes coexist against
  the same repo. Descriptions are stored in `.sandbox-state.json`.

### Notes
- The picker is skipped when no container exists yet (first run stays instant)
  and when non-interactive (CI/headless), preserving the previous default
  single-container behavior.
- Session-topic detection is best-effort and repo-wide: with multiple containers
  in one repo it may show the wrong session's summary, so it's labeled a guess
  (`~"..."`). The typed description is the reliable per-container label.

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

[1.0.8]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.8
[1.0.7]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.7
[1.0.6]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.6
[1.0.5]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.5
[1.0.4]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.4
[1.0.3]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.3
[1.0.2]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.2
[1.0.1]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.1
[1.0.0]: https://github.com/rshamsy/claude-sandbox-plugin/releases/tag/v1.0.0
