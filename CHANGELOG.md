# Changelog

All notable changes to Godot LLM Bridge are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.0] - unreleased

Open-source Community Edition release. `VERSION` at the repo root is the
single source of truth for versioning; `scripts/check_version.py` (and CI)
verify both `bridge/*/plugin.cfg` files match it.

### Added — S-series (upstreamed from MergingWorlds)

- `recover` command: one-shot bridge self-heal that gathers live state,
  picks the recovery action (editor down > orphan game > game-up-but-bridge
  down > breaked game), executes it, and reports the plan it followed.
- Self-healing `launch`/`restart`: process-hygienic startup that validates
  the project path, refuses (or with `--force`, clears) a second editor,
  detaches the child, kills the spawned editor on timeout, warns on an
  orphan game, and has `restart` stop the game and wait on the editor PID
  before relaunching.
- DAP integration: auto-attach on failed `game.*` commands (a runtime error
  now surfaces the pause reason, engine error text, paused stack, and a DAP
  log tail inline), plus `debugger clear-breakpoints` to remove leftover
  editor breakpoints that would otherwise be passed to every spawned game.
- Reason-aware error classes: CLI failures are classified from the carried
  transport reason/code (e.g. `editor_down`, `game_unreachable`,
  `bridge_dropped`) so callers and agents can branch on `error_class`.
- Generalized suite-result reading: `suite-result --path <file>` replaces
  the fixed `--which` choices, and accurately distinguishes missing,
  unreadable, and invalid-JSON result files.
- `DebugBridge.register_handler(name, callback)` extension point for
  game-specific `game.*` handlers, keeping the core bridge game-agnostic.
- Custom-handler documentation: `bridge/game/GUIDE.md` and the
  `debug-bridge` skill cover registering and dispatching custom handlers.

### Unreleased — finalization before the 3.0.0 tag

- `doctor` command: environment and setup diagnostics.
- `launch` version gate: warn on unsupported Godot versions.
- Error-UX sweep: consistent, actionable messages across all failure paths.
- Windows parity pass for launch/process handling.
- Polished installation docs for the open-source release.

## [2.0.0]

- EditorBridge + DebugBridge split with the file-mailbox architecture and
  real DAP debugging; closed-loop driving (held input, telemetry, batch
  reads, bounded retry); portable game-agnostic `bridge/` layout.
