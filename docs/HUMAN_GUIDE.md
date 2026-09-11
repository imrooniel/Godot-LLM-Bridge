# Human Guide: Godot LLM Bridge

## What is Godot LLM Bridge?

The **Godot LLM Bridge** (EditorBridge + DebugBridge) is a system that enables external CLI tools, scripts, and AI agents to interact with the Godot editor and running game processes. It provides a reliable, programmatic interface for:

- Inspecting and modifying the editor state (scenes, files, autoloads).
- Querying and manipulating the running game's scene tree, properties, and UI.
- Performing real DAP (Debug Adapter Protocol) debugging: breakpoints, stepping, stack traces, and variable evaluation.

**GDScript-First by Default:** The bridge works purely with GDScript and Godot nodes. Lua support via the `lua-gdextension` plugin is optional and can be enabled if your project uses Lua. If the Lua extension is not present or not enabled, Lua-specific commands will not be available, and the bridge will function seamlessly with GDScript autoloads and nodes.

## Installation

The bridge is self-contained in the `bridge/` folder (fully game-agnostic — no
game-specific code). Copy the `bridge/` folder into your Godot 4 project, then:

### 1. Add the Game Autoload

In your `project.godot` `[autoload]` section:

```ini
[autoload]

DebugBridge="*res://bridge/autoloads/debug_bridge.gd"
```

### 2. Enable the Editor Plugins

In `project.godot` `[editor_plugins]` (or via **Project → Project Settings → Plugins**):

```ini
[editor_plugins]

enabled=PackedStringArray("res://bridge/editor_bridge/plugin.cfg", "res://bridge/human_edit/plugin.cfg")
```

This enables **Editor Bridge** (the mailbox server + DAP) and **HumanEdit** (captures
human editor edits as content deltas).

### 3. Install the CLI

The Python CLI script is located in `bridge/cli/editor_bridge_cli.py`. It requires no
external Python dependencies.

Then hook in your own game: see `bridge/game/GUIDE.md` (a minimal worked sample is in
`bridge/game/example/`).

## CLI Overview

The CLI is the primary interface for interacting with the Godot editor and game:

```bash
# Launch editor and wait for bridge readiness
python bridge/cli/editor_bridge_cli.py launch

# Restart editor reliably (quit + wait + launch; preferred over the engine's
# own editor-restart, whose relaunch can fail silently)
python bridge/cli/editor_bridge_cli.py restart

# Check editor liveness (heartbeat)
python bridge/cli/editor_bridge_cli.py ping

# Query full state (editor + game)
python bridge/cli/editor_bridge_cli.py query state

# Editor queries
python bridge/cli/editor_bridge_cli.py query editor
python bridge/cli/editor_bridge_cli.py query fs-scenes
python bridge/cli/editor_bridge_cli.py query autoloads

# Scene lifecycle actions
python bridge/cli/editor_bridge_cli.py action scene-open res://scenes/main.tscn
python bridge/cli/editor_bridge_cli.py action scene-play --path res://scenes/main.tscn
python bridge/cli/editor_bridge_cli.py action scene-stop

# Game queries & actions (proxied to DebugBridge)
python bridge/cli/editor_bridge_cli.py game ping
python bridge/cli/editor_bridge_cli.py game game-status
python bridge/cli/editor_bridge_cli.py game inspect-tree root --depth 3
python bridge/cli/editor_bridge_cli.py game get <node_path> <prop>
python bridge/cli/editor_bridge_cli.py game set <node_path> <prop> <value>

# Held input — drive a controller that polls Input.get_vector / is_action_pressed.
# (game key only fires _input callbacks and will NOT move a polling controller.)
python bridge/cli/editor_bridge_cli.py game hold W          # press AND hold (marks move_forward held)
python bridge/cli/editor_bridge_cli.py game held-keys       # show currently held keys/actions
python bridge/cli/editor_bridge_cli.py game release W       # ALWAYS release when done

# Per-frame telemetry — observe motion (position/rotation over time), not a snapshot
python bridge/cli/editor_bridge_cli.py game watch --nodes Main/Player --props '["global_position","rotation.y"]' --hz 30
python bridge/cli/editor_bridge_cli.py game sample --limit 3
python bridge/cli/editor_bridge_cli.py game telemetry-stop

# Batch reads — many (node, prop) pairs in one round-trip
python bridge/cli/editor_bridge_cli.py game get-many Main/Player Main/Player --props global_position rotation.y

# Idempotent read commands (get/get-many/watch/sample/held-keys/screenshot/...) auto-retry
# up to 3x on a transient bridge drop; mutations (set/hold/release/call) never blind-retry.
# Pass --no-retry to a read to disable retry.

# Verified readback — make "done" mean "verified", not asserted
python bridge/cli/editor_bridge_cli.py game godot-status      # richer state: scenes, bridge_port, breakpoint_count, paused note
python bridge/cli/editor_bridge_cli.py action scripts-check res://scripts/my_scene_builder.gd  # compile gate: parses before you trust it
python bridge/cli/editor_bridge_cli.py action script-run res://scripts/my_scene_builder.gd     # run a scene-builder script; runtime exceptions surface as logic_error
python bridge/cli/editor_bridge_cli.py action eval "MyStateHub.party[0].hp"                    # gd-eval: read game state via the runtime

# DAP Debugger commands
python bridge/cli/editor_bridge_cli.py debugger state
python bridge/cli/editor_bridge_cli.py debugger attach
python bridge/cli/editor_bridge_cli.py debugger breaks
python bridge/cli/editor_bridge_cli.py debugger output --max-lines 50
```

## Key Features

### File-Mailbox Architecture

Requests and responses are JSON files under `.tmp/bridge/`:
- `.tmp/bridge/inbox/<id>.json` — CLI → editor request
- `.tmp/bridge/outbox/<id>.json` — editor → CLI response
- `.tmp/bridge/state.json` — heartbeat + full state (updated every 250 ms)

This design eliminates socket management, half-open connections, and leaked ports. Parallel CLI invocations are safe by construction.

### Real DAP Debugging

The system hooks into Godot's built-in Debug Adapter Protocol server (port 6006), providing real debugging capabilities:
- Breakpoints and conditional breaks
- Stepping (step-over, step-into, step-out)
- Call stack inspection
- Variable evaluation and scope inspection

### Two-Process Model

- **Editor Process**: Handles editor state, scene lifecycle, and DAP debugging via `EditorBridge`.
- **Game Process**: Handles game state, autoloads, and UI via `DebugBridge` (TCP 127.0.0.1:5555).

Game operations (`game.*` commands) are proxied by the editor to the game process. Always run `game ping` before issuing `game.*` commands to verify the bridge is ready.

### Verified Readback

The bridge treats a "done" claim as *verified*, not asserted:

- **Compile gate** — `action scripts-check <path>` runs the real GDScript parser and
  reports a `PARSE ERROR` (with file:line) for each script that fails. This is the
  authoritative check; do not rely on a script "loading" — a parse failure is a
  distinct, reported outcome, not a silent pass.
- **Richer `godot-status`** — reports the open scenes, the bridge port, the breakpoint
  count, and, when the game is paused, an actionable note. A paused game is surfaced
  instead of masquerading as healthy.
- **Runtime exceptions surfaced** — `action script-run` turns a runtime exception in a
  run script into an explicit `logic_error`, so a crash is reported rather than read as
  a successful run.

See `bridge/game/GUIDE.md` for the builder's readback contract.

## Examples

See `bridge/game/example/` for a minimal worked sample (a player, an NPC, a transition
zone, and a state-hub autoload) demonstrating the hook-in pattern, and
`bridge/game/GUIDE.md` for the full contract.
