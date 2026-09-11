# Godot LLM Bridge

**EditorBridge + DebugBridge** — Something to make your llm less blind and more capable of interacting with godot editor as it works with you on the project. A file-mailbox bridge between the Godot editor and external CLI tools/LLMs for programmatic game state inspection, UI interaction, and real DAP debugging. Works purely with GDScript and Godot nodes by default; Lua support via `lua-gdextension` is optional.

## 🌟 Key Features

- **File-Mailbox Architecture**: No sockets, no half-open connections. Requests and responses are JSON files under `.tmp/bridge/`, making parallel invocations safe by construction.
- **Real DAP Debugging**: Hooks into Godot's built-in Debug Adapter Protocol (port 6006) for breakpoints, stepping, call stacks, and variable evaluation via the CLI.
- **Two-Process Clarity**: Clear separation between the Editor process (EditorBridge) and the Game process (DebugBridge on 127.0.0.1:5555).
- **GDScript-First by Default**: The bridge works purely with GDScript and Godot nodes. Lua support via `lua-gdextension` is optional and can be enabled if your project uses Lua.
- **Closed-Loop Driving**: Drive a running game and observe it over time — held input (`game hold`/`release`, which drives polling controllers that `game key` cannot), per-frame **telemetry** (`game watch`/`sample`) to watch position/rotation/physics change frame-to-frame, **batch reads** (`game get-many`) in one round-trip, and **bounded auto-retry** on idempotent reads.
- **Heartbeat Liveness**: `.tmp/bridge/state.json` carries a heartbeat (updated every 250 ms). The `ping` command verifies editor and game liveness before actions.
- **Verified, not asserted**: a first-class **compile gate** (`action scripts-check`) and a richer `godot-status` mean "done" is backed by a readback — a broken script can't be mistaken for a clean one, and a paused game is surfaced with an actionable note. See `bridge/game/GUIDE.md`.
- **Self-contained & game-agnostic**: everything lives in a single portable `bridge/` folder with no game-specific code — drop it into any Godot 4 project.

## 📦 Installation

The bridge is self-contained in the `bridge/` folder. Copy that folder into your Godot 4 project, then:

1. **Add the game autoload** — in your `project.godot` `[autoload]` section:

   ```ini
   [autoload]
   DebugBridge="*res://bridge/autoloads/debug_bridge.gd"
   ```

2. **Enable the two editor plugins** — in `project.godot` `[editor_plugins]`:

   ```ini
   [editor_plugins]
   enabled=PackedStringArray("res://bridge/editor_bridge/plugin.cfg", "res://bridge/human_edit/plugin.cfg")
   ```

   (or enable **Editor Bridge** and **HumanEdit** under **Project → Project Settings → Plugins**).

3. **The CLI** — `bridge/cli/editor_bridge_cli.py` has no external Python dependencies.

Then hook in your own game: see `bridge/game/GUIDE.md` (a minimal worked sample is in `bridge/game/example/`).

## 🚀 Quick Start

```bash
# Launch the editor and wait for the bridge
python bridge/cli/editor_bridge_cli.py launch

# Check liveness
python bridge/cli/editor_bridge_cli.py ping

# Query editor state
python bridge/cli/editor_bridge_cli.py query state

# Play a scene
python bridge/cli/editor_bridge_cli.py action scene-play --path res://scenes/main.tscn

# Verify game bridge
python bridge/cli/editor_bridge_cli.py game ping

# Attach DAP debugger
python bridge/cli/editor_bridge_cli.py debugger attach
```

### Drive, verify, and gate (closed loop)

```bash
# Observe motion over time (per-frame telemetry)
python bridge/cli/editor_bridge_cli.py game watch --nodes Main/Player --props '["global_position","rotation.y"]' --hz 30

# Drive a polling controller with held input (game key won't move it)
python bridge/cli/editor_bridge_cli.py game hold W
python bridge/cli/editor_bridge_cli.py game sample --limit 3   # position should be changing
python bridge/cli/editor_bridge_cli.py game release W

# Batch reads in one round-trip
python bridge/cli/editor_bridge_cli.py game get-many Main/Player --props global_position rotation.y

# Compile gate: prove a script parses before you trust it
python bridge/cli/editor_bridge_cli.py action scripts-check res://scripts/my_scene_builder.gd

# Read back the live game state (scenes, port, breakpoints, paused note)
python bridge/cli/editor_bridge_cli.py game godot-status
```

## 📚 Documentation

- `bridge/README.md` — layout, install, and how to hook in your game.
- [Human Guide](docs/HUMAN_GUIDE.md) — installation, usage, and key features for game developers and CI/CD engineers.
- **Agent Skills** — live under `bridge/skills/`: `editor-bridge/SKILL.md`, `debug-bridge/SKILL.md`, `drive/SKILL.md`, `human-edit/SKILL.md`.
- [Bridge Improvement Plan](docs/bridge-improvement-plan.md) — design rationale and verification for the closed-loop driving features.

## 📄 License

MIT License
