# Agent Skill: EditorBridge

The EditorBridge is a **file-mailbox bridge** between CLI tools and the Godot editor (`addons/editor_bridge/`). No sockets in the editor: requests and responses are JSON files under `.tmp/bridge/`, so there are no half-open connections, no leaked ports, and crashed clients leave only orphan files (auto-purged). The human uses the editor UI normally at the same time — no conflicts.

```
.tmp/bridge/inbox/<id>.json         CLI -> editor request (atomic write+rename)
.tmp/bridge/outbox/<id>.json        editor -> CLI response
.tmp/bridge/events/<client>.jsonl   streaming events for subscribers
.tmp/bridge/state.json              heartbeat + full state (every 250 ms)
```

**Liveness is measured, not assumed:** `state.json` carries a heartbeat; a heartbeat older than 2 s means the editor is dead. `ping` checks this.

## ⛔ Two-process model (read this first)

**The game runs as a SEPARATE OS process** from the editor (spawned via `OS.create_instance` with `--remote-debug`). Project autoloads (LuaVM, GameSession, …) exist ONLY in the game process.

- `query.*` / `action.*` / `logs.*` / `debugger.*` → **editor process**
- `game.*` → **proxied by the editor to the game process** (TCP 127.0.0.1:5555, DebugBridge autoload). Fails with a clear error when no game is running.
- Game console output reaches the editor's Output panel via the debugger protocol; structured game logs come from the in-game log collector via `game logs`.

## Golden rules

1. **The CLI is the ONLY way to start the editor** (`launch`), and the only way to operate it. Never spawn the godot binary directly.
2. **`ping` (or `query state`) before every action** — fail fast if the editor is dead. `query state` is the single source of truth for editor + game state.
3. **`game ping` before any `game.*` command** — verifies a game is actually running and reachable.
4. One CLI invocation = one request file. **Parallel invocations are safe by construction** (no shared connection). Long-lived streaming (`subscribe listen`) runs in its own process alongside one-shots.

## Editing bridge commands without restarting the editor

Editor commands are **loaded from disk at call time** (`addons/editor_bridge/commands/<name>.gd`, `CACHE_MODE_IGNORE`). Edit a command file and the very next CLI call runs the new code — **no editor restart**. Only changes to the core (`editor_bridge.gd`, `game_proxy.gd`, …) need a restart.

## Launch & connect

```bash
# Launch editor (auto-detects Godot binary; set GODOT_EDITOR_BINARY to override)
python3 scripts/editor_bridge_cli.py launch

# Liveness check (heartbeat freshness, no round trip)
python3 scripts/editor_bridge_cli.py ping

# Full state: editor, scenes (open/current/unsaved), game (running/scene/bridge)
python3 scripts/editor_bridge_cli.py query state
```

Editor startup takes up to ~45 s; `launch` waits for a fresh heartbeat. If the editor dies early or never becomes ready, `launch` prints the tail of `.tmp/logs/editor-console.log` — the captured editor stdout is the ONLY record of pre-plugin-init output (startup parse errors land there).

## Editor queries

```bash
python3 scripts/editor_bridge_cli.py query state
python3 scripts/editor_bridge_cli.py query editor
python3 scripts/editor_bridge_cli.py query fs-scenes
python3 scripts/editor_bridge_cli.py query autoloads
python3 scripts/editor_bridge_cli.py query scene res://scenes/landing.tscn
python3 scripts/editor_bridge_cli.py query scene-tree res://scenes/landing.tscn --depth 3
python3 scripts/editor_bridge_cli.py query fs <res://path>
python3 scripts/editor_bridge_cli.py query fs-scripts --path res://scripts
```

> **Note on `query autoloads`:** This command returns `{"autoloads": []}` because it queries **editor-side** autoloads, which are empty. Project autoloads (`GameSession`, `LuaVM`, `UIManager`, `DebugLog`, `ModLoader`, `DebugBridge`, `GameBridge`, `SaveManager`) exist in the **game process**. Use `python3 scripts/editor_bridge_cli.py game inspect-tree root --depth 3` to view game-process autoloads.

## Scene lifecycle

```bash
python3 scripts/editor_bridge_cli.py action scene-open res://scenes/combat.tscn
python3 scripts/editor_bridge_cli.py action scene-close [res://scenes/x.tscn]   # closes CURRENT scene (no close-by-path API)
python3 scripts/editor_bridge_cli.py action scene-save [--path res://scenes/x.tscn]
python3 scripts/editor_bridge_cli.py action scene-save-all
python3 scripts/editor_bridge_cli.py action scene-play [--path res://scenes/x.tscn]  # no --path = main scene
python3 scripts/editor_bridge_cli.py action scene-stop
python3 scripts/editor_bridge_cli.py action scene-reload res://scenes/x.tscn
python3 scripts/editor_bridge_cli.py action scripts-reload            # all scripts (may take a while)
python3 scripts/editor_bridge_cli.py action scripts-reload-one res://scripts/foo.gd
python3 scripts/editor_bridge_cli.py action editor-restart            # DANGEROUS: kills the session
python3 scripts/editor_bridge_cli.py action editor-close              # DANGEROUS: quits the editor
```

`scene-play` refuses if a game is already running; `scene-stop` errors with "Nothing is running" otherwise. Game state is read from `EditorInterface.is_playing_scene()` — reliable, not tree-sniffing. Scene open/close/save events are detected by the core's state diff, so they fire for **human UI actions too**.

> **⚠️ Game Bridge Initialization Timing:** After `action scene-play`, the game bridge takes a moment to fully initialize. Always run `python3 scripts/editor_bridge_cli.py game ping` and wait for it to return `{"game_bridge": true}` (or `{"game_running": true}` in state) before issuing any other `game.*` commands. This prevents "Game bridge unreachable" errors.

## Game queries & actions (proxied to the running game)

```bash
python3 scripts/editor_bridge_cli.py game ping                 # editor state + game pong
python3 scripts/editor_bridge_cli.py game game-status          # scene name, in_combat
python3 scripts/editor_bridge_cli.py game scene-info
python3 scripts/editor_bridge_cli.py game inspect-tree [path] --depth N
python3 scripts/editor_bridge_cli.py game get <node_path> <prop>
python3 scripts/editor_bridge_cli.py game signals <node_path>
python3 scripts/editor_bridge_cli.py game methods <node_path> [--pattern x]
python3 scripts/editor_bridge_cli.py game scan-ui [--root root] [--types Button Label]
python3 scripts/editor_bridge_cli.py game find-nodes [--root root] [--name-pattern "Hex*"] [--type Node2D]
python3 scripts/editor_bridge_cli.py game inspect-control <node_path>
python3 scripts/editor_bridge_cli.py game screenshot [user://path.png]   # prints local_path too
python3 scripts/editor_bridge_cli.py game screenshot-b64 --scale 0.5
python3 scripts/editor_bridge_cli.py game logs --from 0 --max-lines 500
python3 scripts/editor_bridge_cli.py game clear-logs

# Actions
python3 scripts/editor_bridge_cli.py game signal <node_path> pressed [args...]
python3 scripts/editor_bridge_cli.py game call <node_path> <method> [args...]
python3 scripts/editor_bridge_cli.py game set <node_path> <prop> <value>   # JSON values
python3 scripts/editor_bridge_cli.py game key ENTER --release
python3 scripts/editor_bridge_cli.py game mouse click 400 300 [--button 1]
python3 scripts/editor_bridge_cli.py game mouse move 400 300
python3 scripts/editor_bridge_cli.py game click-node <node_path>
python3 scripts/editor_bridge_cli.py game time-scale 0.5          # never 0.0 (crashes)
python3 scripts/editor_bridge_cli.py game quit

> **Note on Lua support:** Lua-specific commands (`lua-eval`, `lua-eval-act`, `call LuaVM ...`) require the `lua-gdextension` plugin to be enabled in your project. If the Lua extension is not present or not enabled, these commands will not be available. The bridge works purely with GDScript and Godot nodes by default.
```

**UI note:** UI is built dynamically with auto-generated node names (like `@Button@39`) that change every session — never hardcode them. `scan-ui` → match by text → use the returned path. Prefer `lua-eval` for test setup.

## Console & logs

```bash
# Editor-side logs:
python3 scripts/editor_bridge_cli.py logs get --from 0 --max-lines 500 --source auto
python3 scripts/editor_bridge_cli.py logs clear
# Game-side logs (in-game collector; only while game runs):
python3 scripts/editor_bridge_cli.py game logs --from 0 --max-lines 500
```

`logs get --source`:
- `panel` — the editor Output panel: editor output **and** game output (the only source that captures the game process). A rolling view (subject to human filters/clear/10k cap).
- `collector` — editor-process Logger (prints + script/engine errors).
- `process` — captured editor stdout from `.tmp/logs/editor-console.log` (current launch section; pre-plugin-init startup output).
- `auto` — panel if available, else collector (default).

## Events (streaming — own process)

```bash
python3 scripts/editor_bridge_cli.py subscribe listen              # all events
python3 scripts/editor_bridge_cli.py subscribe events game_started game_stopped scene_opened
python3 scripts/editor_bridge_cli.py subscribe state               # full-state snapshots on change
python3 scripts/editor_bridge_cli.py subscribe console             # Output panel lines (editor + game)
python3 scripts/editor_bridge_cli.py subscribe debugger            # raw debugger packets
```

Event names: `log`, `console`, `scene_opened`, `scene_closed`, `scene_saved`, `game_started`, `game_stopped`, `state`, `debugger_packet`, `script_reloaded`, `scripts_reloaded`.

Run the subscriber in the background (e.g. a separate terminal or `&`); one-shot commands keep working in parallel (multi-client by construction).

## Debugger (real DAP, 4.8+)

The engine's built-in **Debug Adapter Protocol** server is driven over TCP and proxied through the same CLI. This is real debugging — breakpoints, stepping, stack, variables, evaluate — not a stub.

```bash
python3 scripts/editor_bridge_cli.py debugger state               # connected/attached/breaked
python3 scripts/editor_bridge_cli.py debugger attach              # attach to the running game (auto on break/unbreak)
python3 scripts/editor_bridge_cli.py debugger launch --scene res://scenes/combat.tscn
python3 scripts/editor_bridge_cli.py debugger break  res://scripts/foo.gd 42
python3 scripts/editor_bridge_cli.py debugger unbreak res://scripts/foo.gd 42
python3 scripts/editor_bridge_cli.py debugger breaks
python3 scripts/editor_bridge_cli.py debugger pause               # stop a running game
python3 scripts/editor_bridge_cli.py debugger continue
python3 scripts/editor_bridge_cli.py debugger step-over           # (requires paused)
python3 scripts/editor_bridge_cli.py debugger step-into           # (requires paused)
python3 scripts/editor_bridge_cli.py debugger step-out            # (requires paused)
python3 scripts/editor_bridge_cli.py debugger stack               # (requires paused)
python3 scripts/editor_bridge_cli.py debugger vars [--frame N] [--ref ID]
python3 scripts/editor_bridge_cli.py debugger eval '1+1' [--frame N]
python3 scripts/editor_bridge_cli.py debugger output --max-lines 50
```

**How it works:** one persistent DAP client (a core `DapSession` node) owns the TCP connection to the engine's `network/debug_adapter` (port 6006). Commands queue onto it; the matching DAP response is written back to the mailbox. The session idles with a `threads` keepalive every ~4 s (the engine's server rejects any request >5 s after the last client data).

**Gotchas (engine-verified):**
- Exactly ONE DAP client. A *new* client's `initialize` clears ALL editor breakpoints unless `network/debug_adapter/sync_breakpoints=true` (the core sets it at startup).
- `step-out` has no native DAP request — it sends the classic `out` message through the `godot/put_msg` pass-through (the command name contains a **slash**; the server binds `req_` + command).
- `setBreakpoints` requires an **absolute OS path** on the wire (the server's `is_valid_path()` does `begins_with get_resource_path()`); the client globalizes `res://` internally and keeps `res://` for bookkeeping.
- The game must actually be running for any debuggee-bound request to get a response — against a dead game the command times out (that's a symptom, not a protocol bug).
- Raw DAP events stream via `subscribe debugger`.
