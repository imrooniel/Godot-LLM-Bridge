---
name: debug-bridge
description: Use when interacting with a running Godot 4 game from the terminal — inspecting or controlling live game nodes, reading game logs, driving UI, taking screenshots, or debugging via DAP. Trigger keywords: DebugBridge, editor_bridge_cli.py, game ping, game logs, game inspect-tree, game signal, game key, time-scale, screenshot-b64, game game-status, "running game", "game bridge unreachable", DAP debugger attach.
---

# Agent Skill: DebugBridge

Interact with a **running** Godot 4 game from the terminal. Game operations go through the **unified** `bridge/cli/editor_bridge_cli.py` under the `game` subcommand tree. The editor process proxies each request over TCP to the in-game `DebugBridge` autoload (`127.0.0.1:5555`, falls back +1..+9 if busy).

## Two-Process Model (critical)

The game runs as a **separate OS process** from the editor. Your game's autoloads (a game/session manager, save manager, …) exist **only in the game process**. `EditorBridge` (editor process) handles editor state/lifecycle/logs and **proxies** `game.*` commands to the in-game `DebugBridge` (port 5555).

Therefore: `game ping` before any `game.*` command. If the game isn't running, every `game.*` command fails with `Game bridge unreachable`.

## Pre-flight Checklist (DO THIS FIRST)

```bash
# 1. Editor alive? (heartbeat, no round trip)
python3 bridge/cli/editor_bridge_cli.py ping
python3 bridge/cli/editor_bridge_cli.py query state   # full state incl. game.running

# 2. Game bridge reachable? (game must be running)
python3 bridge/cli/editor_bridge_cli.py game ping
# -> { "editor": true, "game_running": true, ... }
```

If `game ping` fails, the game isn't running — start it:

```bash
# Start the editor (auto-detects the Godot binary; waits up to 300s for heartbeat).
# Run this with a tool timeout > 300000 ms.
python3 bridge/cli/editor_bridge_cli.py launch

# Start/stop the game inside the editor:
python3 bridge/cli/editor_bridge_cli.py action scene-play            # play the current scene
python3 bridge/cli/editor_bridge_cli.py action scene-play --path res://scenes/game.tscn
python3 bridge/cli/editor_bridge_cli.py action scene-stop
```

Then `game ping` again to confirm the bridge came up.

## CLI Overview

```
editor_bridge_cli.py
├── launch | restart | recover   # start / quit+wait+launch / one-shot self-heal
├── ping                      # editor liveness (heartbeat)
├── connect                   # verify editor reachable, print state
├── query <state|editor|scene|scene-tree|fs|autoloads|godot-status|human-deltas|...>
├── action <scene-open|scene-play|scene-stop|scene-save|fs-scan|run-script|...>
├── game <ping|inspect-tree|get|set|signal|call|hold|watch|rpc|...>   # proxied to 5555
├── debugger <state|attach|break|clear-breakpoints|pause|step-*|stack|vars|eval|...>  # real DAP
├── subscribe <events|console|debugger|listen|state>
├── logs get --source {auto|panel|collector|process}
└── suite-result --path <result-file>   # trustworthy on-disk test marker (S2/S8)
```

All game commands are one-shot request/response (file mailbox) — parallel invocations are safe. `subscribe listen` is the only long-lived streaming mode.

## Game Command Reference

**Discovery / inspection:**
```bash
python3 bridge/cli/editor_bridge_cli.py game ping
python3 bridge/cli/editor_bridge_cli.py game scene-info
python3 bridge/cli/editor_bridge_cli.py game game-status          # scene name, scene file, bound port
python3 bridge/cli/editor_bridge_cli.py game inspect-tree root --depth 3
python3 bridge/cli/editor_bridge_cli.py game inspect-control MainMenu/StartButton
python3 bridge/cli/editor_bridge_cli.py game find-nodes --type Button --name-pattern "Start*"
python3 bridge/cli/editor_bridge_cli.py game scan-ui --types Button CheckBox
python3 bridge/cli/editor_bridge_cli.py game methods GameManager [--pattern save]
python3 bridge/cli/editor_bridge_cli.py game signals GameManager
```

**Property access** (targets the GDScript node directly):
```bash
python3 bridge/cli/editor_bridge_cli.py game get MainMenu/StartButton text
python3 bridge/cli/editor_bridge_cli.py game set GameManager time_scale 0.5
```

**Expression evaluation** (GDScript in the running game; autoloads/globals resolve):
```bash
python3 bridge/cli/editor_bridge_cli.py game gd-eval "MyStateHub.party[0].hp"
python3 bridge/cli/editor_bridge_cli.py game eval "1 + 2 * 3"     # `eval` = alias of `gd-eval`
python3 bridge/cli/editor_bridge_cli.py game gd-eval "Vector2(3, 4).length()"
```
Syntax is compile-checked **in the editor first** — bad syntax errors out without
touching the game (compile failures return the engine's exact parser message,
e.g. `Static function "get_version_string()" not found` — dogfood BD-008).
Residual (dogfood BD-004): expressions that compile but fail
in-game (bad member on a typed autoload, runtime errors) can trigger the editor's
Break-on-Error and pause the game (`query state` → `debugger.breaked: true`).
Recovery: `action scene-stop` + `action scene-play`. Never eval loops — no
preemption (same contract as `lua-eval`). `gd-eval` is SINGLE-EXPRESSION:
statements → write a project script, call `load("res://x.gd").new().method()`.

**API-drift toolbox (BD-009)** — dev builds remove/rename engine APIs silently
(this build: 4.8-dev; docs memory for ≤4.4 is wrong often):
```bash
python3 bridge/cli/editor_bridge_cli.py game api-class TileSetAtlasSource --filter sep
python3 bridge/cli/editor_bridge_cli.py game reload-script res://scripts/tools/my_scene_builder.gd
```
`api-class` prints properties/methods/signals/enums AS COMPILED IN THIS BUILD —
query it before writing any engine-API code, instead of trusting memory.
`reload-script` hot-reloads a .gd into the running game (edit → reload-script →
call again; no scene restart, deterministic). Pair with `action run-script`
(editor-side, no running game needed) for scene-generation builders.

**Choosing the right inspection tool — the authoritative table (read once):**

| Need | Command | Path / key form | Gotcha (from the dogfood log) |
|---|---|---|---|
| one known property / simple field | `game get <path> <prop>` | **root-relative or absolute** node path | a bare scene-node name fails — use the root-relative form (e.g. `World/Player`) or an absolute path; `find-nodes` returns the correct path to use |
| call a method with args | `game call <path> <method> [args…]` | root-relative | — |
| expressions: chains, indices, math | `game gd-eval "<expr>"` | **autoloads + globals only** | `get_node(...)` does NOT resolve (the eval script is not a node) — reach nodes via `Engine.get_main_loop().root.get_node(...)`; SINGLE-EXPRESSION only — statements go in a project script |
| many reads in one round-trip | `game get-many <path…> --props <props…>` | root-relative | — |
| what APIs does THIS build have? | `game api-class <Class> [--filter x]` | — | **query before writing engine-API code** — dev builds rename/remove APIs silently; docs/training memory is often wrong |
| iterate a tool script without restart | `game reload-script res://scripts/tools/my_scene_builder.gd` | res:// .gd | content-change comparison; a same-second edit can report `unchanged` — confirm with `game methods` before calling |
| hold a **key** to drive a polling controller | `game hold <KEY>` then `game release <KEY>` | **key name** (W/S/A/D/E/SPACE/ENTER…) | `hold` takes a KEY, NOT an action name — `hold interact` fails; the `interact` action is bound to E/SPACE, so it is `hold E`. Always `release` what you `hold`. |
| one key event (fires `_input`, not polling) | `game key <KEY> --release` | key name | does NOT update `Input.is_key_pressed()` — use `hold`/`release` for polling controllers |
| locals / breakpoints / stepping | `debugger attach` + `debugger vars/eval/stack` | — | a paused game is a STATE (`breaked: true`), never a timeout; a `game.*` WRITE while breaked is deferred with `reason: game_paused` |
| Lua-side state (if the Lua extension is enabled) | `game lua-eval` | — | separate namespace — see the Lua-vs-GDScript section below |

**UI interaction** — PREFER `signal` (always works, ignores window scaling):
```bash
python3 bridge/cli/editor_bridge_cli.py game signal MainMenu/StartButton pressed
python3 bridge/cli/editor_bridge_cli.py game click-node Main/GameArea      # clicks node center (less reliable)
```

**Key / mouse** (ALWAYS `--release` a key you pressed):
```bash
python3 bridge/cli/editor_bridge_cli.py game key ENTER --release
python3 bridge/cli/editor_bridge_cli.py game mouse click 400 300
python3 bridge/cli/editor_bridge_cli.py game mouse move 400 300
```

**Method calls (GDScript nodes):**
```bash
python3 bridge/cli/editor_bridge_cli.py game call <node_path> <method> [args...]
```

**Held input** (drive a controller that polls `Input.get_vector` / `is_action_pressed`;
`game key` only fires `_input` callbacks and will NOT move a polling controller):
```bash
python3 bridge/cli/editor_bridge_cli.py game hold W        # press AND hold (marks the mapped action held)
python3 bridge/cli/editor_bridge_cli.py game held-keys     # show currently held keys/actions
python3 bridge/cli/editor_bridge_cli.py game release W     # ALWAYS release when done
```

**Per-frame telemetry** (observe motion over frames — position/rotation/physics change):
```bash
python3 bridge/cli/editor_bridge_cli.py game watch --nodes Main/Player --props '["global_position","rotation.y"]' --hz 30
python3 bridge/cli/editor_bridge_cli.py game sample --limit 3
python3 bridge/cli/editor_bridge_cli.py game telemetry-stop
```

> **Single-client bridge:** space out `game` calls (a burst can read the previous pending
> response). Idempotent reads (e.g. get/get-many/sample/held-keys/screenshot) auto-retry up
> to 3× on a transient drop; mutations (set/hold/release/call) never blind-retry. `--no-retry`
> disables read retry. See the `drive` skill for the full closed-loop workflow.

**Custom handlers (extension point):** the core registers only generic handlers — games add their
own commands with `DebugBridge.register_handler(name, callback)` and call them via
`python3 bridge/cli/editor_bridge_cli.py game rpc <name> [--json-params '{...}']`
(`--params` is an accepted alias).

**In-game scene swap:** `python3 bridge/cli/editor_bridge_cli.py game change-scene res://scenes/x.tscn`
runs `change_scene_to_file` on the game's MAIN thread and awaits the deferred swap completing
(the response means "the new scene is live"). Typical flow: `game set <your session autoload>
<config prop> '{...}'` first, then `change-scene` to the scene that reads it.

> **Note on Lua support:** Lua-specific commands (`lua-eval`, `lua-eval-act`) require the `lua-gdextension` plugin to be enabled in your project AND the game to hand its Lua VM to the bridge (`DebugBridge.set_lua_vm(node)` at startup). Without a registered VM these commands fail with a `lua_vm_not_registered` error. The bridge works purely with GDScript and Godot nodes by default.

**Screenshots / time / crashes:**
```bash
python3 bridge/cli/editor_bridge_cli.py game screenshot user://my_screen.png
python3 bridge/cli/editor_bridge_cli.py game screenshot-b64 --scale 0.5
python3 bridge/cli/editor_bridge_cli.py game time-scale 0.5   # never 0.0 — freezes the game AND stalls the game bridge (≥ 0.1)
python3 bridge/cli/editor_bridge_cli.py game crashes [--max-lines 50]   # recent crash/error entries + flag
python3 bridge/cli/editor_bridge_cli.py game clear-crashes
```

**Game logs (in-memory collector; cleared each game run):**
```bash
python3 bridge/cli/editor_bridge_cli.py game logs --from 0 --max-lines 500
python3 bridge/cli/editor_bridge_cli.py game clear-logs
```

**NOTE on `scan-ui --types`:** matches exact Godot class names only (`Button`, `CheckBox`, `LineEdit`, `TextEdit`, `OptionButton`, `Slider`). Superclass names like `Control` / `BaseButton` return nothing.

## ⚠️ Lua vs GDScript Namespace (Only if Lua extension is enabled)

If your project has the `lua-gdextension` plugin enabled and a registered Lua VM, be aware that Lua and GDScript have **separate namespaces for autoloads.** Writing `GameManager.save_slots` via `lua-eval` sets the Lua-side `GameManager` table — **NOT** the GDScript autoload `GameManager`. This is a common source of silent bugs where Lua-side tables are modified instead of the GDScript autoloads.

**CRITICAL RULE (if Lua is enabled):**
- **Never use `lua-eval` to modify GDScript autoload properties.**
- Use `python3 bridge/cli/editor_bridge_cli.py game set <node_path> <prop> <value>` for **GDScript autoload properties** (e.g., your game manager).
- Use `python3 bridge/cli/editor_bridge_cli.py game lua-eval` **only** for Lua module APIs (if applicable).

```bash
# CORRECT — writes the GDScript GameManager autoload property:
python3 bridge/cli/editor_bridge_cli.py game set GameManager save_slots '{"slots":[1,2]}'

# WRONG — Lua-side GameManager is a separate table, invisible to GDScript (if Lua is enabled):
python3 bridge/cli/editor_bridge_cli.py game lua-eval 'GameManager.save_slots = {...}'
```

Use `set`/`call`/`get` for GDScript autoload properties. If the `lua-gdextension` is not enabled or not present in your project, the bridge works purely with GDScript and Godot nodes, and Lua-specific commands are not available.

## DAP Workflows: `debugger launch` vs `debugger attach`

The `debugger launch` and `debugger attach` commands are for **mutually exclusive** workflows. Do not use both simultaneously:

- **Workflow A (Editor Play + DAP Attach):** Use `action scene-play --path <scene>` to start the game inside the editor, then run `python3 bridge/cli/editor_bridge_cli.py debugger attach` to connect to the running game via DAP.
- **Workflow B (DAP Launch):** Use `python3 bridge/cli/editor_bridge_cli.py debugger launch --scene <scene>` to start the game *through* DAP. **Do not** use `action scene-play` in this case.

Using `debugger launch --scene <scene>` when the game is already running via `action scene-play` will cause a timeout or "DAP not connected" error.

## Reading Logs — two different sources

- **`game logs`** → the **in-game** DebugBridge collector. Only works while the game is running; auto-cleared at the start of each game run.
- **`logs get --source …`** → editor-side sources (works even when the game is stopped):
  ```bash
  python3 bridge/cli/editor_bridge_cli.py logs get --source auto --max-lines 500
  # --source: auto | panel | collector | process
  ```
  `panel` = editor output panel (threaded `RichTextLabel`; read via `get_parsed_text()`, not `get_text()`). `process` = the captured godot process stdout (`.tmp/logs/`). `collector` = the game log collector.

### Reading test-harness output

Bridge tests print whatever markers the harness defines; the reliable channel is
the harness's **on-disk result file**, read via
`python3 bridge/cli/editor_bridge_cli.py suite-result --path <file>` (user://,
res://-adjacent, absolute, or project-relative). It survives a bridge drop, so
a missing console summary is never a pass (S2/S8).

- The game log collector grows during play (thousands of lines in a long session) — page with `--from` / `--tail`.

## Common Mistakes

- **`game.*` without a running game** → `Game bridge unreachable`. `game ping` first; start the game with `action scene-play`.
- **Orphaned game process** → doesn't crash the editor (launch warns), but it can hold bridge port 5555 so the new game binds another port and the proxy may talk to the wrong process. `action scene-stop` (or kill the game) before restarting.
- **Wrong `game` subcommand spelling** → they are **hyphenated**: `lua-eval`, `scan-ui`, `find-nodes`, `click-node`, `time-scale`, `screenshot-b64`, `clear-logs`, `game-status`, `inspect-tree`, `inspect-control`. The CLI rejects the underscore forms.
- **Compound bash commands** → prefer one command per tool call where possible.
- **`time-scale 0.0`** → doesn't crash, but freezes the game AND stalls the game bridge (its socket-poll Timer ticks in scaled time; later `game.*` commands time out). Use ≥ 0.1; recover from a stuck 0 with `action scene-stop` or `recover`.
- **Game boots paused (`breaked: true`)** → leftover editor breakpoints ride along to every spawned game. `debugger clear-breakpoints` before `action scene-play`.
- **Re-running `scene-play` on a failed `game.*`** → the game is usually paused, not dead; the CLI prints an inline pause report. `debugger continue` to resume, or `recover` for the one-shot heal.
- **Key press without `--release`** → leaves the key held.
- **`click-node`/`mouse`** → coordinate-dependent; prefer `signal … pressed`.
- **Unquoted `@` paths / hardcoded `@Button@N`** → auto-generated node ids change every run. Always `scan-ui`/`find-nodes` first, then match by text.

## Core-file reload caveat

`DebugBridge`/`GameBridge` are autoloads loaded at engine start. If you edit `debug_bridge.gd` or `game_bridge.gd` and new RPC handlers don't appear, restart the **game** (`action scene-stop` then `action scene-play`) — Godot reloads autoloads on a new game run. This does NOT apply to regular scene scripts (which hot-reload during play), and should never be the default explanation when a fix "doesn't work" — check logs first.
