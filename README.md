# Godot LLM Bridge

**EditorBridge + DebugBridge** — Something to make your llm less blind and more capable of interacting with godot editor as it works with you on the project. A file-mailbox bridge between the Godot editor and external CLI tools/LLMs for programmatic game state inspection, UI interaction, and real DAP debugging. Works purely with GDScript and Godot nodes by default; Lua support via `lua-gdextension` is optional.

## 🌟 Key Features

- **File-Mailbox Architecture**: No sockets, no half-open connections. Requests and responses are JSON files under `.tmp/bridge/`, making parallel invocations safe by construction.
- **Real DAP Debugging**: Hooks into Godot's built-in Debug Adapter Protocol (port 6006) for breakpoints, stepping, call stacks, and variable evaluation via the CLI.
- **Two-Process Clarity**: Clear separation between the Editor process (EditorBridge) and the Game process (DebugBridge on 127.0.0.1:5555).
- **GDScript-First by Default**: The bridge works purely with GDScript and Godot nodes. Lua support via `lua-gdextension` is optional and can be enabled if your project uses Lua.
- **Closed-Loop Driving**: Drive a running game and observe it over time — held input (`game hold`/`release`, which drives polling controllers that `game key` cannot), per-frame **telemetry** (`game watch`/`sample`) to watch position/rotation/physics change frame-to-frame, **batch reads** (`game get-many`) in one round-trip, and **bounded auto-retry** on idempotent reads.
- **Heartbeat Liveness**: `.tmp/bridge/state.json` carries a heartbeat (updated every 250 ms). The `ping` command verifies editor and game liveness before actions.

## 📦 Installation

1. **Enable the Editor Plugin**: 
   - Copy the `addons/editor_bridge/` folder to your Godot project's `addons/` directory.
   - Open **Project → Project Settings → Plugins** and enable **EditorBridge**.

2. **Add the Game Autoload**:
   - Copy `autoloads/debug_bridge.gd` and `autoloads/debug_log_collector.gd` to your project.
   - Add `DebugBridge="*res://debug_bridge.gd"` to the `[autoload]` section in your `project.godot`.

3. **Install the CLI**:
   - The Python CLI script is located in `scripts/editor_bridge_cli.py`. No external Python dependencies are required.

## 🚀 Quick Start

```bash
# Launch the editor and wait for the bridge
python scripts/editor_bridge_cli.py launch

# Check liveness
python scripts/editor_bridge_cli.py ping

# Query editor state
python scripts/editor_bridge_cli.py query state

# Play a scene
python scripts/editor_bridge_cli.py action scene-play --path res://scenes/main.tscn

# Verify game bridge
python scripts/editor_bridge_cli.py game ping

# Attach DAP debugger
python scripts/editor_bridge_cli.py debugger attach
```

### Driving a running game (closed loop)

```bash
# Observe motion over time (per-frame telemetry)
python scripts/editor_bridge_cli.py game watch --nodes Main/Player --props '["global_position","rotation.y"]' --hz 30

# Drive a polling controller with held input (game key won't move it)
python scripts/editor_bridge_cli.py game hold W
python scripts/editor_bridge_cli.py game sample --limit 3   # position should be changing
python scripts/editor_bridge_cli.py game release W

# Batch reads in one round-trip
python scripts/editor_bridge_cli.py game get-many Main/Player --props global_position rotation.y
```

## 📚 Documentation

- [Human Guide](docs/HUMAN_GUIDE.md) — Installation, usage, and key features for game developers and CI/CD engineers.
- [Agent Skills](docs/AGENT_SKILLS/) — Documentation for LLMs and AI agents (`editor-bridge.md`, `debug-bridge.md`, `drive.md`).
- [Bridge Improvement Plan](docs/bridge-improvement-plan.md) — Design rationale and verification for the closed-loop driving features.

## 📄 License

MIT License
