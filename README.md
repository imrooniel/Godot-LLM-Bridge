# Godot LLM Bridge

**EditorBridge + DebugBridge** — make your AI coding agent stop guessing at
your Godot editor. A file-mailbox bridge between the Godot editor / running
game and external CLI tools (LLM agents, CI scripts), for programmatic editor
control, game-state inspection, UI interaction, and real DAP debugging —
purely GDScript + stdlib Python; the editor↔CLI path is a file mailbox, so
there are no half-open sockets to go stale.

Works purely with GDScript and Godot nodes; Lua support via
`lua-gdextension` is optional (the bridge stays agnostic — projects register
their own RPC handlers).

## Requirements

| | |
|---|---|
| **Godot** | **4.7+** for the core bridge (CI-tested on 4.7.2). `debugger …` commands need **4.8+** — the engine's built-in Debug Adapter Protocol server is 4.8+ only; on 4.7 they answer a clear "DAP not connected" error (or `connected: false`), everything else works. |
| **OS** | Windows 10/11 and Linux (CLI test suite CI-covered on both; the editor-runtime integration job is Linux-only today). macOS is not tested and out of scope for support; community patches welcome. |
| **Python** | 3.9+ (CLI is stdlib-only — zero pip installs; CI-tested on 3.11 & 3.12). |

> As of Oct 2026 the newest **official stable** Godot is 4.7.2; 4.8 lives in
> dev builds. The bridge is developed against 4.8-dev and gated on 4.7.2 in
> CI, so 4.8 regressions get caught when 4.8-stable lands.

## Install (5 minutes)

1. **Copy the `bridge/` folder** from this repo into your project root.
   It is fully self-contained — no game-specific code inside.

2. **Register the game autoload** — in your `project.godot`:

   ```ini
   [autoload]

   DebugBridge="*res://bridge/autoloads/debug_bridge.gd"
   ```

3. **Enable the two editor plugins** — in the same file:

   ```ini
   [editor_plugins]

   enabled=PackedStringArray("res://bridge/editor_bridge/plugin.cfg", "res://bridge/human_edit/plugin.cfg")
   ```

   (or toggle **Editor Bridge** + **HumanEdit** under
   *Project → Project Settings → Plugins*).

4. **That's the install.** The CLI is `bridge/cli/editor_bridge_cli.py`.
   Use `python3` on Linux/macOS, `python` on Windows — every command below
   uses `python3`; substitute on Windows. No environment variables needed:
   the CLI finds your Godot binary from `GODOT_EDITOR_BINARY`, a
   project-local `.godot-editor-path` file, or `PATH` (in that order).

Want game-specific RPC handlers (your Lua VM, your combat state)? Register
them from YOUR code — see `bridge/game/GUIDE.md`
(`bridge/game/example/` is a minimal worked sample).

## Agent skills (OpenCode is the supported harness)

Ready-made agent skills ship in `bridge/skills/`: `editor-bridge`,
`debug-bridge`, `drive`, `human-edit`. For auto-discovery, copy them into
your project:

```bash
mkdir -p .opencode/skills && cp -r bridge/skills/* .opencode/skills/
```

```powershell
New-Item -ItemType Directory -Force .opencode\skills | Out-Null
Copy-Item bridge\skills\* .opencode\skills\ -Recurse
```

Other harnesses: point your agent at the `SKILL.md` files — they're plain
markdown command manuals.

## First session

```bash
# 1. Start the editor through the CLI (it waits until the bridge is alive)
python3 bridge/cli/editor_bridge_cli.py launch

# 2. Liveness — heartbeat from the editor, no round trip needed
python3 bridge/cli/editor_bridge_cli.py ping

# 3. What does the editor see right now?
python3 bridge/cli/editor_bridge_cli.py query state

# 4. Run the (demo) game from a scene
python3 bridge/cli/editor_bridge_cli.py action scene-play --path res://scenes/main.tscn

# 5. Talk to the running game
python3 bridge/cli/editor_bridge_cli.py game scene-info
python3 bridge/cli/editor_bridge_cli.py game logs --from 0

# 6. Health check — run this whenever something behaves oddly
python3 bridge/cli/editor_bridge_cli.py doctor
```

Every command prints JSON and exits nonzero on failure. Game-command
failures carry a structured `{code, message, reason, suggested}` envelope;
editor-side failures print the reason plus `suggested:` follow-up lines —
either way, `suggested` tells you the next command to run.

## Daily driving

```bash
# Compile gate: prove scripts parse before trusting anything
python3 bridge/cli/editor_bridge_cli.py action scripts-check res://scripts/player.gd

# One-shot property read
python3 bridge/cli/editor_bridge_cli.py game get Main/Player global_position

# Batch reads, one round trip (--props pairs 1:1 with the node paths)
python3 bridge/cli/editor_bridge_cli.py game get-many Main/Player Main/Enemy --props global_position rotation.y

# Held input drives polling controllers (a `game key` tap won't)
python3 bridge/cli/editor_bridge_cli.py game hold W
python3 bridge/cli/editor_bridge_cli.py game watch --nodes Main/Player --props '["global_position"]' --hz 30   # starts the per-frame sampler
python3 bridge/cli/editor_bridge_cli.py game sample --limit 3    # last 3 samples — position should be changing
python3 bridge/cli/editor_bridge_cli.py game release W
python3 bridge/cli/editor_bridge_cli.py game telemetry-stop

# Full picture: editor, game, debugger, scenes
python3 bridge/cli/editor_bridge_cli.py query godot-status
```

Extend the bridge to your game (Lua VM, custom queries) with one call from
your autoload: `get_node("/root/DebugBridge").register_handler("my_query", callable)`.

## Troubleshooting

**First move: `python3 bridge/cli/editor_bridge_cli.py doctor`.** It checks
the project file, Godot feature floor and binary discovery, Python,
autoload/plugin registration, editor heartbeat, and OS support — each
failure prints the fix, and it runs with no editor open. Paste its output
when asking for help.

| Symptom | Likely cause / fix |
|---|---|
| `editor not reachable (no fresh heartbeat)` | No editor launched through this CLI, or it died. Run `launch` (or `recover` once). |
| `game …` commands refuse or time out | Game not running (`action scene-play …`), or the `DebugBridge` autoload is missing from your `project.godot` (then the connect is refused outright). |
| Editor starts but game never boots | A leftover breakpoint pauses the game at start: `debugger clear-breakpoints`, then `recover`. |
| `debugger …` says DAP not available | You're on Godot < 4.8 — expected; the DAP server is engine-side. |
| Two editors fighting over the mailbox | One editor per project directory — the CLI refuses to launch a second; close the other editor. |
| Everything worked, then went stale | `query state` reads the heartbeat — if `alive: false`, run `recover` once. |

## Reporting issues

[Open a bug report](/issues/new?template=bug_report.yml) — it asks for
`doctor` output (required), your OS, and exact Godot version
(`godot --version`). Logs live under `.tmp/logs/` and `.tmp/bridge/`;
attach the tails.

## Documentation

- `bridge/README.md` — folder layout + how to hook your game in.
- [Human guide](docs/HUMAN_GUIDE.md) — deeper walkthrough (install, usage, CI).
- `bridge/skills/*/SKILL.md` — the agent-facing command manuals (canonical).
- [Bridge improvement plan](docs/bridge-improvement-plan.md) — design
  rationale for the closed-loop driving features.

## License

[MIT](LICENSE).
