# Human Guide: Godot LLM Bridge

## What is Godot LLM Bridge?

The **Godot LLM Bridge** (EditorBridge + DebugBridge) is a system that enables external CLI tools, scripts, and AI agents to interact with the Godot editor and running game processes. It provides a reliable, programmatic interface for:

- Inspecting and modifying the editor state (scenes, files, autoloads).
- Querying and manipulating the running game's scene tree, properties, and UI.
- Performing real DAP (Debug Adapter Protocol) debugging: breakpoints, stepping, stack traces, and variable evaluation.

**GDScript-First by Default:** The bridge works purely with GDScript and Godot nodes. Lua support via the `lua-gdextension` plugin is optional and can be enabled if your project uses Lua. If the Lua extension is not present or not enabled, Lua-specific commands will not be available, and the bridge will function seamlessly with GDScript autoloads and nodes.

## Installation

### 1. Enable the Editor Plugin

1. Copy the `addons/editor_bridge/` folder to your Godot project's `addons/` directory.
2. Open **Project → Project Settings → Plugins**.
3. Find **EditorBridge** and enable it.

### 2. Add the Game Autoload

1. Copy `debug_bridge.gd` and `debug_log_collector.gd` from the `autoloads/` folder to your project's root directory.
2. Open your `project.godot` file and add the following to the `[autoload]` section:

```ini
[autoload]

DebugBridge="*res://debug_bridge.gd"
```

### 3. Install the CLI

The Python CLI script is located in `scripts/editor_bridge_cli.py`. It requires no external Python dependencies.

## CLI Overview

The CLI is the primary interface for interacting with the Godot editor and game:

```bash
# Launch editor and wait for bridge readiness
python scripts/editor_bridge_cli.py launch

# Check editor liveness (heartbeat)
python scripts/editor_bridge_cli.py ping

# Query full state (editor + game)
python scripts/editor_bridge_cli.py query state

# Editor queries
python scripts/editor_bridge_cli.py query editor
python scripts/editor_bridge_cli.py query fs-scenes
python scripts/editor_bridge_cli.py query autoloads

# Scene lifecycle actions
python scripts/editor_bridge_cli.py action scene-open res://scenes/main.tscn
python scripts/editor_bridge_cli.py action scene-play --path res://scenes/main.tscn
python scripts/editor_bridge_cli.py action scene-stop

# Game queries & actions (proxied to DebugBridge)
python scripts/editor_bridge_cli.py game ping
python scripts/editor_bridge_cli.py game game-status
python scripts/editor_bridge_cli.py game inspect-tree root --depth 3
python scripts/editor_bridge_cli.py game get <node_path> <prop>
python scripts/editor_bridge_cli.py game set <node_path> <prop> <value>

# DAP Debugger commands
python scripts/editor_bridge_cli.py debugger state
python scripts/editor_bridge_cli.py debugger attach
python scripts/editor_bridge_cli.py debugger breaks
python scripts/editor_bridge_cli.py debugger output --max-lines 50
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

## Examples

See the `examples/minimal_project/` folder for a minimal Godot 4.8 project demonstrating the setup.
