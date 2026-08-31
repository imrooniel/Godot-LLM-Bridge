# Agent Skill: DebugBridge

Interact with a **running** Godot 4 game from the terminal. Game operations go through the **unified** `scripts/editor_bridge_cli.py` under the `game` subcommand tree. The editor process proxies each request over TCP to the in-game `DebugBridge` autoload (`127.0.0.1:5555`, falls back +1..+9 if busy).

## Two-Process Model (critical)

The game runs as a **separate OS process** from the editor. Autoloads (`LuaVM`, `GameSession`, …) exist **only in the game process**. `EditorBridge` (editor process) handles editor state/lifecycle/logs and **proxies** `game.*` commands to the in-game `DebugBridge` (port 5555).

Therefore: `game ping` before any `game.*` command. If the game isn't running, every `game.*` command fails with `Game bridge unreachable`.

## Pre-flight Checklist (DO THIS FIRST)

```bash
# 1. Editor alive? (heartbeat, no round trip)
python3 scripts/editor_bridge_cli.py ping
python3 scripts/editor_bridge_cli.py query state   # full state incl. game.running

# 2. Game bridge reachable? (game must be running)
python3 scripts/editor_bridge_cli.py game ping
# -> { "editor": true, "game_running": true, ... }
```

If `game ping` fails, the game isn't running — start it:

```bash
# Start the editor (auto-detects the Godot binary; waits up to 300s for heartbeat).
# Run this with a tool timeout > 300000 ms.
python3 scripts/editor_bridge_cli.py launch

# Start/stop the game inside the editor:
python3 scripts/editor_bridge_cli.py action scene-play            # play the current scene
python3 scripts/editor_bridge_cli.py action scene-play --path res://scenes/combat.tscn
python3 scripts/editor_bridge_cli.py action scene-stop
```

Then `game ping` again to confirm the bridge came up.

## CLI Overview

```
editor_bridge_cli.py
├── launch                    # start the editor, wait for heartbeat
├── ping                      # editor liveness (heartbeat)
├── connect                   # verify editor reachable, print state
├── query <state|editor|scene|scene-tree|fs|...>
├── action <scene-open|scene-play|scene-stop|scene-save|...|editor-restart|...>
├── game <ping|inspect-tree|get|set|signal|call|...>     # proxied to 5555
├── debugger <state|attach|break|pause|step-*|stack|vars|eval|...>  # real DAP
├── subscribe <events|console|debugger|listen|state>
└── logs get --source {auto|panel|collector|process}
```

All game commands are one-shot request/response (file mailbox) — parallel invocations are safe. `subscribe listen` is the only long-lived streaming mode.

## Game Command Reference

**Discovery / inspection:**
```bash
python3 scripts/editor_bridge_cli.py game ping
python3 scripts/editor_bridge_cli.py game scene-info
python3 scripts/editor_bridge_cli.py game game-status          # scene name, in_combat flag
python3 scripts/editor_bridge_cli.py game inspect-tree root --depth 3
python3 scripts/editor_bridge_cli.py game inspect-control MainMenu/StartButton
python3 scripts/editor_bridge_cli.py game find-nodes --type Button --name-pattern "Start*"
python3 scripts/editor_bridge_cli.py game scan-ui --types Button CheckBox
python3 scripts/editor_bridge_cli.py game methods LuaVM [--pattern foo]
python3 scripts/editor_bridge_cli.py game signals GameSession
```

**Property access** (targets the GDScript node directly):
```bash
python3 scripts/editor_bridge_cli.py game get MainMenu/StartButton text
python3 scripts/editor_bridge_cli.py game set GameSession time_scale 0.5
```

**UI interaction** — PREFER `signal` (always works, ignores window scaling):
```bash
python3 scripts/editor_bridge_cli.py game signal MainMenu/StartButton pressed
python3 scripts/editor_bridge_cli.py game click-node Main/HexGrid      # clicks node center (less reliable)
```

**Key / mouse** (ALWAYS `--release` a key you pressed):
```bash
python3 scripts/editor_bridge_cli.py game key ENTER --release
python3 scripts/editor_bridge_cli.py game mouse click 400 300
python3 scripts/editor_bridge_cli.py game mouse move 400 300
```

**Method calls (GDScript nodes):**
```bash
python3 scripts/editor_bridge_cli.py game call <node_path> <method> [args...]
```

> **Note on Lua support:** Lua-specific commands (`lua-eval`, `lua-eval-act`, `call LuaVM ...`) require the `lua-gdextension` plugin to be enabled in your project. If the Lua extension is not present or not enabled, these commands will not be available. The bridge works purely with GDScript and Godot nodes by default.

**Screenshots / time:**
```bash
python3 scripts/editor_bridge_cli.py game screenshot user://my_screen.png
python3 scripts/editor_bridge_cli.py game screenshot-b64 --scale 0.5
python3 scripts/editor_bridge_cli.py game time-scale 0.5   # NEVER 0.0 — it crashes the game
```

**Game logs (in-memory collector; cleared each game run):**
```bash
python3 scripts/editor_bridge_cli.py game logs --from 0 --max-lines 500
python3 scripts/editor_bridge_cli.py game clear-logs
```

**NOTE on `scan-ui --types`:** matches exact Godot class names only (`Button`, `CheckBox`, `LineEdit`, `TextEdit`, `OptionButton`, `Slider`). Superclass names like `Control` / `BaseButton` return nothing.

## ⚠️ Lua vs GDScript Namespace (Only if Lua extension is enabled)

If your project has the `lua-gdextension` plugin enabled and the `LuaVM` autoload, be aware that Lua and GDScript have **separate namespaces for autoloads.** Writing `GameSession.combat_config` via `lua-eval` sets the Lua-side `GameSession` table — **NOT** the GDScript autoload `GameSession`. This is a common source of silent bugs where Lua-side tables are modified instead of the GDScript autoloads.

**CRITICAL RULE (if Lua is enabled):**
- **Never use `lua-eval` to modify GDScript autoload properties.**
- Use `python3 scripts/editor_bridge_cli.py game set <node_path> <prop> <value>` for **GDScript autoload properties** (e.g., `GameSession`).
- Use `python3 scripts/editor_bridge_cli.py game lua-eval` **only** for Lua module APIs (if applicable).

```bash
# CORRECT — writes the GDScript GameSession autoload:
python3 scripts/editor_bridge_cli.py game set GameSession combat_config '{"players":[...]}'

# WRONG — Lua-side GameSession is a separate table, invisible to GDScript (if Lua is enabled):
python3 scripts/editor_bridge_cli.py game lua-eval 'GameSession.combat_config = {...}'
```

Use `set`/`call`/`get` for GDScript autoload properties. If the `lua-gdextension` is not enabled or not present in your project, the bridge works purely with GDScript and Godot nodes, and Lua-specific commands are not available.

## DAP Workflows: `debugger launch` vs `debugger attach`

The `debugger launch` and `debugger attach` commands are for **mutually exclusive** workflows. Do not use both simultaneously:

- **Workflow A (Editor Play + DAP Attach):** Use `action scene-play --path <scene>` to start the game inside the editor, then run `python3 scripts/editor_bridge_cli.py debugger attach` to connect to the running game via DAP.
- **Workflow B (DAP Launch):** Use `python3 scripts/editor_bridge_cli.py debugger launch --scene <scene>` to start the game *through* DAP. **Do not** use `action scene-play` in this case.

Using `debugger launch --scene <scene>` when the game is already running via `action scene-play` will cause a timeout or "DAP not connected" error.

## Reading Logs — two different sources

- **`game logs`** → the **in-game** DebugBridge collector. Only works while the game is running; auto-cleared at the start of each game run.
- **`logs get --source …`** → editor-side sources (works even when the game is stopped):
  ```bash
  python3 scripts/editor_bridge_cli.py logs get --source auto --max-lines 500
  # --source: auto | panel | collector | process
  ```
  `panel` = editor output panel (threaded `RichTextLabel`; read via `get_parsed_text()`, not `get_text()`). `process` = the captured godot process stdout (`.tmp/logs/`). `collector` = the game log collector.

### Key Log Tags

| Tag | Source | Purpose |
|-----|--------|---------|
| `[PROJ_DBG]` | GDScript + Lua | Projectile lifecycle: spawn, reconcile, snapshot, frames, death |
| `[SEG_COLLIDE]` | Lua | Segment-level projectile collision summary |
| `[SEG_PVP]` | Lua | Projectile-vs-projectile damage (with HP snapshots) |
| `[SEG_HIT]` | Lua | Individual hit: damage dealt, target HP before/after |
| `[COMMIT]` | Lua | Turn commit: grid placement, animation building |
| `[PLAN]` | Lua | Turn plan: occupancy, conflicts |
| `[RESOLVE]` | Lua | Hex-level collision resolution |
| `[RECONCILE]` | GDScript | Renderer reconciliation (snap, create, orphan removal) |
| `[ANIM_START]` / `[ANIM_FRAME]` / `[ANIM_COMPLETE]` / `[ANIM_INTERRUPTED]` | GDScript | Animation lifecycle |
| `[DEATH_START]` / `[DEATH_COMPLETE]` | GDScript | Death animation lifecycle |
| `[COLLIDE]` | Lua | Hex-level collision resolver |
| `[TEST PASS/FAIL/SKIP/SUMMARY]` | Lua test runner | Test results |

- Lua logs are prefixed `[Lua]`; GDScript `print()` has no prefix.
- The collector grows during play (thousands of lines in a long session).

## Common Mistakes

- **`game.*` without a running game** → `Game bridge unreachable`. `game ping` first; start the game with `action scene-play`.
- **Orphaned game process** → a leftover game process crashes a new editor on launch. `action scene-stop` (or kill the game) before restarting the editor.
- **Wrong `game` subcommand spelling** → they are **hyphenated**: `lua-eval`, `scan-ui`, `find-nodes`, `click-node`, `time-scale`, `screenshot-b64`, `clear-logs`, `game-status`, `inspect-tree`, `inspect-control`. The CLI rejects the underscore forms.
- **Compound bash commands** → prefer one command per tool call where possible.
- **`time-scale 0.0`** → crashes the game.
- **Key press without `--release`** → leaves the key held.
- **`click-node`/`mouse`** → coordinate-dependent; prefer `signal … pressed`.
- **Unquoted `@` paths / hardcoded `@Button@N`** → auto-generated node ids change every run. Always `scan-ui`/`find-nodes` first, then match by text.

## Core-file reload caveat

`DebugBridge`/`GameBridge` are autoloads loaded at engine start. If you edit `debug_bridge.gd` or `game_bridge.gd` and new RPC handlers don't appear, restart the **game** (`action scene-stop` then `action scene-play`) — Godot reloads autoloads on a new game run. This does NOT apply to regular scene scripts (which hot-reload during play), and should never be the default explanation when a fix "doesn't work" — check logs first.
