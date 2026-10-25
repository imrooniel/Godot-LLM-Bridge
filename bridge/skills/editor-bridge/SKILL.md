---
name: editor-bridge
description: Use when driving the Godot editor from the terminal — launching the editor, opening/saving/playing/stopping scenes, querying editor state or the scene tree, reading editor logs, subscribing to events, or debugging via DAP. Trigger keywords: EditorBridge, editor_bridge_cli.py, launch, restart, recover, doctor, ping, query state, scene-open, scene-play, scene-stop, scene-save, fs-scan, clear-breakpoints, debugger, subscribe, "Godot editor", file-mailbox bridge, editor bridge.
---

# Agent Skill: EditorBridge

The EditorBridge is a **file-mailbox bridge** between CLI tools and the Godot editor (`bridge/editor_bridge/`). No sockets in the editor: requests and responses are JSON files under `.tmp/bridge/`, so there are no half-open connections, no leaked ports, and crashed clients leave only orphan files (auto-purged). The human uses the editor UI normally at the same time — no conflicts.

```
.tmp/bridge/inbox/<id>.json         CLI -> editor request (atomic write+rename)
.tmp/bridge/outbox/<id>.json        editor -> CLI response
.tmp/bridge/events/<client>.jsonl   streaming events for subscribers
.tmp/bridge/state.json              heartbeat + full state (every 250 ms)
```

**Liveness is measured, not assumed:** `state.json` carries a heartbeat; a heartbeat older than 2 s means the editor is dead. `ping` checks this.

## ⛔ Two-process model (read this first)

**The game runs as a SEPARATE OS process** from the editor (spawned via `OS.create_instance` with `--remote-debug`). Your game's autoloads (a game/session manager, save manager, …) exist ONLY in the game process.

- `query.*` / `action.*` / `logs.*` / `debugger.*` → **editor process**
- `game.*` → **proxied by the editor to the game process** (TCP 127.0.0.1:5555, DebugBridge autoload). Fails with a clear error when no game is running.
- Game console output reaches the editor's Output panel via the debugger protocol; structured game logs come from the in-game log collector via `game logs`.

## Golden rules

1. **Never run Godot headless** for testing — headless catches nothing (no compile errors, no real script loading). The editor is the source of truth.
2. **The CLI is the ONLY way to start the editor** (`launch`), and the only way to operate it. Never spawn the godot binary directly — a second editor instance corrupts the shared mailbox and breaks the single source of truth.
3. **`ping` (or `query state`) before every action** — fail fast if the editor is dead. `query state` is the single source of truth for editor + game state.
4. **`game ping` before any `game.*` command** — verifies a game is actually running and reachable.
5. One CLI invocation = one request file. **Parallel invocations are safe by construction** (no shared connection). Long-lived streaming (`subscribe listen`) runs in its own process alongside one-shots.
6. Created a script with `class_name`? `action fs-scan --wait` before playing — class registration happens ONLY on a filesystem scan (see Scene lifecycle).
7. Restart via the CLI's `restart` command, not `action editor-restart` — the engine's own relaunch is best-effort and can fail silently, leaving the editor dead with no trace.
8. Something wedged (editor down, orphan game, paused-at-boot game)? **`recover`** — one command that diagnoses and heals, instead of a manual sequence.

## Choosing the right channel — read once

The full, authoritative table (every `game` verb + its path/key form + the dogfood
gotcha) lives in `bridge/skills/debug-bridge/SKILL.md` under **"Choosing the right
inspection tool — the authoritative table."** The editor-side (non-game) channel:

| Need | Command | Note |
|---|---|---|
| is the editor alive? | `ping` | heartbeat, no round trip |
| the one call to make each turn | `query godot-status` | returns editor + game + scenes + debugger (incl. `breaked`, `breakpoint_count`); a paused game is a state, never a timeout |
| full state | `query state` | editor + scenes + game + debugger |
| open / save / play / stop a scene | `action scene-open/save/play/stop` | `scene-play` reports the running scene; a paused-on-boot game is surfaced by `godot-status` |
| compile-check scripts before running | `action scripts-check res://a.gd [res://b.gd …]` | first-class gate for the run-script loop |
| run a repo-script method in the editor | `action run-script res://x.gd <method> [args…]` | surfaces **runtime** exceptions as `logic_error` (not a silent success); finish with `action fs-scan` (new `.tscn`/`.tres` are invisible to the editor until the rescan) |
| evaluate ONE editor expression | `action eval "<expr>"` | single expression; policy-checked |
| read the human's edits since last turn | `query human-deltas [--since <turn>]` | content deltas (turn handoff) |
| something wedged | `recover` | relaunch editor / kill orphan / replay scene / continue a breaked game |
| is the SETUP right (install/diagnosis)? | `doctor [--path DIR] [--json]` | static checks: project file, Godot feature floor (4.7+/4.8-DAP), Python, binary discovery, autoload+plugin registration, heartbeat, OS; one `fix:` per FAIL; exit 0 iff no FAIL; works with no editor running — run it FIRST when a stranger's bridge misbehaves |

## Editing bridge commands without restarting the editor

Editor commands are **loaded from disk at call time** (`bridge/editor_bridge/commands/<name>.gd`, `CACHE_MODE_IGNORE`). Edit a command file and the very next CLI call runs the new code — **no editor restart**. Only changes to the core (`editor_bridge.gd`, `game_proxy.gd`, …) need a restart.

## Launch & connect

Binary detection order: `GODOT_EDITOR_BINARY` env → project-local `.godot-editor-path` file (one line, absolute or project-relative path — the right home for custom builds; machine-local, keep it out of git) → PATH → registry → common install locations.

```bash
# Launch editor (auto-detects the Godot binary; see detection order above).
# Startup can take a while (first import after an engine upgrade reimports
# everything); launch waits up to 300 s — give the call a tool timeout > 300000 ms.
python3 bridge/cli/editor_bridge_cli.py launch
# launch gates the engine version (Error [godot_version] = below the supported
# floor — repin the binary per doctor/CONTRIBUTING; relaunching won't help).

# Reliable restart: stop game + quit + wait for the PID to die + launch.
# ('action editor-restart' is the ENGINE's restart = quit + best-effort spawn
# whose failure is silently ignored. Prefer this command.)
python3 bridge/cli/editor_bridge_cli.py restart

# One-shot self-heal: picks the recovery action from live state and reports a
# single status. Precedence: editor down > orphan game > game-up-but-bridge-down
# > breaked (paused) game > ok.
python3 bridge/cli/editor_bridge_cli.py recover

# Setup diagnosis (no editor needed): install, registration, binary,
# heartbeat, OS — actionable fix per FAIL, --json for machines.
python3 bridge/cli/editor_bridge_cli.py doctor

# Liveness check (heartbeat freshness, no round trip)
python3 bridge/cli/editor_bridge_cli.py ping

# Full state: editor, scenes (open/current/unsaved), game (running/scene/bridge)
python3 bridge/cli/editor_bridge_cli.py query state
```

`launch` is process-hygienic: it validates the project path, refuses to start when another editor is already running on this project, kills a spawned editor that never becomes ready, and only warns about (never silently kills) an orphan game process — `launch --force` additionally SIGKILLs a lingering editor and orphan games so a stale pid never blocks a relaunch. Editor stdout is captured to `.tmp/logs/editor-console.log` — the ONLY record of pre-plugin-init output (startup parse errors land there); `launch` prints its tail if the editor dies early or never becomes ready.

## Editor queries

```bash
python3 bridge/cli/editor_bridge_cli.py query state
python3 bridge/cli/editor_bridge_cli.py query editor
python3 bridge/cli/editor_bridge_cli.py query fs-scenes
python3 bridge/cli/editor_bridge_cli.py query autoloads
python3 bridge/cli/editor_bridge_cli.py query scene res://scenes/main.tscn
python3 bridge/cli/editor_bridge_cli.py query scene-tree res://scenes/main.tscn --depth 3
python3 bridge/cli/editor_bridge_cli.py query fs <res://path>
python3 bridge/cli/editor_bridge_cli.py query fs-scripts --path res://scripts
python3 bridge/cli/editor_bridge_cli.py query dialogs               # visible editor dialogs
python3 bridge/cli/editor_bridge_cli.py action dialog-accept --ok-button "Reload from disk"
```

> **Note on `query autoloads`:** This command returns `{"autoloads": []}` because it queries **editor-side** autoloads, which are empty. Your game's autoloads (a game/session manager, save manager, …) exist in the **game process**. Use `python3 bridge/cli/editor_bridge_cli.py game inspect-tree root --depth 3` to view game-process autoloads.

## Scene lifecycle

```bash
python3 bridge/cli/editor_bridge_cli.py action scene-open res://scenes/game.tscn
python3 bridge/cli/editor_bridge_cli.py action scene-close [res://scenes/x.tscn]   # closes CURRENT scene (no close-by-path API)
python3 bridge/cli/editor_bridge_cli.py action scene-save [--path res://scenes/x.tscn]
python3 bridge/cli/editor_bridge_cli.py action scene-save-all
python3 bridge/cli/editor_bridge_cli.py action scene-play [--path res://scenes/x.tscn]  # no --path = main scene
python3 bridge/cli/editor_bridge_cli.py action scene-stop
python3 bridge/cli/editor_bridge_cli.py action scene-reload res://scenes/x.tscn
python3 bridge/cli/editor_bridge_cli.py action scripts-reload            # all scripts (may take a while)
python3 bridge/cli/editor_bridge_cli.py action scripts-reload-one res://scripts/foo.gd
python3 bridge/cli/editor_bridge_cli.py action fs-scan --wait            # rescan FS — REQUIRED after creating a script with `class_name`
python3 bridge/cli/editor_bridge_cli.py action editor-restart            # DANGEROUS: engine quit + SILENT best-effort relaunch; prefer `restart`
python3 bridge/cli/editor_bridge_cli.py action editor-close              # DANGEROUS: quits the editor
```

**Code execution in the EDITOR** (BD-007 — works with NO running game):
```bash
# Run a method of a repo script (SAFE channel — git-reviewable code, fresh from disk):
python3 bridge/cli/editor_bridge_cli.py action run-script res://scripts/tools/my_scene_builder.gd build
# Evaluate ONE expression (editor process; runtime classes by name; strict policy):
python3 bridge/cli/editor_bridge_cli.py action eval "Engine.get_version_info()['string']"
```
`run-script` is THE scene/tool-generation channel: builders as plain .gd files,
instantiated fresh per call (non-@tool scripts get @tool injected automatically).
Finish generation with `action fs-scan`. `action eval` refuses statements,
over-long expressions, and anything touching `quit_editor`/`save_quit`/
`quit_play` — prefer `run-script` for anything multi-step. Runtime classes only:
`EditorInterface` is NOT reachable from eval (use the dedicated `query`/`action`
commands). Game-side equivalent of both: `game gd-eval` + the builder pattern.

`scene-play` refuses if a game is already running; `scene-stop` errors with "Nothing is running" otherwise. Game state is read from `EditorInterface.is_playing_scene()` — reliable, not tree-sniffing. Scene open/close/save events are detected by the core's state diff, so they fire for **human UI actions too**.

**New `class_name` scripts: `action fs-scan` is mandatory.** The engine
registers global classes ONLY during a filesystem scan
(`EditorFileSystem::_update_script_classes`) — `scripts-reload` re-executes
cached scripts but never touches the registry. Creating `scripts/foo.gd` with
`class_name Foo` while the editor runs, then playing a scene that references
`Foo`, fails SILENTLY: the game process exits on the compile error, so
`game ping` shows `game_running: false` + `game_bridge: false`, and the error
is NOT in `logs --source process` (game stdout ≠ editor stdout).
Workflow: create script → `action fs-scan --wait` → `scene-play`.

> **⚠️ Game Bridge Initialization Timing:** After `action scene-play`, the game bridge takes a moment to fully initialize. Always run `python3 bridge/cli/editor_bridge_cli.py game ping` and wait for it to return `{"game_bridge": true}` (or `{"game_running": true}` in state) before issuing any other `game.*` commands. This prevents "Game bridge unreachable" errors.

## Game queries & actions (proxied to the running game)

```bash
python3 bridge/cli/editor_bridge_cli.py game ping                 # editor state + game pong
python3 bridge/cli/editor_bridge_cli.py game game-status          # scene_name, scene_file, bound port
python3 bridge/cli/editor_bridge_cli.py game scene-info
python3 bridge/cli/editor_bridge_cli.py game inspect-tree [path] --depth N
python3 bridge/cli/editor_bridge_cli.py game get <node_path> <prop>
python3 bridge/cli/editor_bridge_cli.py game signals <node_path>
python3 bridge/cli/editor_bridge_cli.py game methods <node_path> [--pattern x]
python3 bridge/cli/editor_bridge_cli.py game scan-ui [--root root] [--types Button Label]
python3 bridge/cli/editor_bridge_cli.py game find-nodes [--root root] [--name-pattern "Enemy*"] [--type Node2D]
python3 bridge/cli/editor_bridge_cli.py game inspect-control <node_path>
python3 bridge/cli/editor_bridge_cli.py game screenshot [user://path.png]   # prints local_path too; --wait-ms to settle
python3 bridge/cli/editor_bridge_cli.py game screenshot-b64 --scale 0.5
python3 bridge/cli/editor_bridge_cli.py game logs --from 0 --max-lines 500
python3 bridge/cli/editor_bridge_cli.py game clear-logs
python3 bridge/cli/editor_bridge_cli.py game crashes [--max-lines 50]       # recent crash/error entries + flag
python3 bridge/cli/editor_bridge_cli.py game clear-crashes

# Actions
python3 bridge/cli/editor_bridge_cli.py game signal <node_path> pressed [args...]
python3 bridge/cli/editor_bridge_cli.py game call <node_path> <method> [args...]
python3 bridge/cli/editor_bridge_cli.py game set <node_path> <prop> <value>   # JSON values
python3 bridge/cli/editor_bridge_cli.py game key ENTER --release
python3 bridge/cli/editor_bridge_cli.py game mouse click 400 300 [--button 1]
python3 bridge/cli/editor_bridge_cli.py game mouse move 400 300
python3 bridge/cli/editor_bridge_cli.py game click-node <node_path>
python3 bridge/cli/editor_bridge_cli.py game time-scale 0.5          # never 0.0 (freezes the game AND the game bridge)
python3 bridge/cli/editor_bridge_cli.py game change-scene res://scenes/x.tscn  # main-thread scene swap; awaits the deferred swap completing
python3 bridge/cli/editor_bridge_cli.py game rpc <name> [--json-params '{...}']  # game-registered handler (see debug-bridge skill)
python3 bridge/cli/editor_bridge_cli.py game quit

# Lua — ONLY if the lua-gdextension plugin is enabled AND the game registered its VM
python3 bridge/cli/editor_bridge_cli.py game lua-eval '<lua code>'
python3 bridge/cli/editor_bridge_cli.py game lua-eval-act '<lua code>'
```

> **Note on Lua support:** Lua-specific commands (`lua-eval`, `lua-eval-act`) require the `lua-gdextension` plugin to be enabled in your project AND the game to hand its Lua VM to the bridge (`DebugBridge.set_lua_vm(node)` at startup). Without a registered VM these commands fail with a `lua_vm_not_registered` error. The bridge works purely with GDScript and Godot nodes by default.

**Node paths:** root-relative (the form `scan-ui`/`find-nodes` return, e.g.
`MenuScreen/StartButton`) or absolute (`/root/MenuScreen/StartButton`) — both
resolve identically. Prefer root-relative to match what the discovery commands
print.

**UI note:** UI built dynamically has auto-generated node names (like
`@Button@39`) that change every session — never hardcode them. `scan-ui` →
match by text → use the returned path.

## Console & logs

```bash
# Editor-side logs:
python3 bridge/cli/editor_bridge_cli.py logs get --from 0 --max-lines 500 --source auto
python3 bridge/cli/editor_bridge_cli.py logs clear
# Game-side logs (in-game collector; only while game runs):
python3 bridge/cli/editor_bridge_cli.py game logs --from 0 --max-lines 500
```

`logs get --source`:
- `panel` — the editor Output panel: editor output **and** game output (the only source that captures the game process). A rolling view (subject to human filters/clear/10k cap).
- `collector` — editor-process Logger (prints + script/engine errors).
- `process` — captured editor stdout from `.tmp/logs/editor-console.log` (current launch section; pre-plugin-init startup output).
- `auto` — panel if available, else collector (default).

## Events (streaming — own process)

```bash
python3 bridge/cli/editor_bridge_cli.py subscribe listen              # all events
python3 bridge/cli/editor_bridge_cli.py subscribe events game_started game_stopped scene_opened
python3 bridge/cli/editor_bridge_cli.py subscribe state               # full-state snapshots on change
python3 bridge/cli/editor_bridge_cli.py subscribe console             # Output panel lines (editor + game)
python3 bridge/cli/editor_bridge_cli.py subscribe debugger            # raw DAP packets
```

Event names: `log`, `console`, `scene_opened`, `scene_closed`, `scene_saved`, `game_started`, `game_stopped`, `state`, `debugger_packet`, `script_reloaded`, `scripts_reloaded`.

Run the subscriber in the background (e.g. a separate terminal or `&`); one-shot commands keep working in parallel (multi-client by construction).

## Debugger (real DAP, 4.8+)

The engine's built-in **Debug Adapter Protocol** server is driven over TCP and proxied through the same CLI. This is real debugging — breakpoints, stepping, stack, variables, evaluate — not a stub.

```bash
python3 bridge/cli/editor_bridge_cli.py debugger state               # connected/attached/breaked
python3 bridge/cli/editor_bridge_cli.py debugger attach              # attach to the running game (auto on break/unbreak)
python3 bridge/cli/editor_bridge_cli.py debugger detach              # detach (game keeps running)
python3 bridge/cli/editor_bridge_cli.py debugger launch --scene res://scenes/game.tscn
python3 bridge/cli/editor_bridge_cli.py debugger break  res://scripts/foo.gd 42
python3 bridge/cli/editor_bridge_cli.py debugger unbreak res://scripts/foo.gd 42
python3 bridge/cli/editor_bridge_cli.py debugger breaks
python3 bridge/cli/editor_bridge_cli.py debugger clear-breakpoints   # remove ALL editor breakpoints (leftover ones pause spawned games at boot)
python3 bridge/cli/editor_bridge_cli.py debugger pause               # stop a running game
python3 bridge/cli/editor_bridge_cli.py debugger continue
python3 bridge/cli/editor_bridge_cli.py debugger step-over           # (requires paused)
python3 bridge/cli/editor_bridge_cli.py debugger step-into           # (requires paused)
python3 bridge/cli/editor_bridge_cli.py debugger step-out            # (requires paused)
python3 bridge/cli/editor_bridge_cli.py debugger stack               # (requires paused)
python3 bridge/cli/editor_bridge_cli.py debugger vars [--frame N] [--ref ID]
python3 bridge/cli/editor_bridge_cli.py debugger eval '1+1' [--frame N]
python3 bridge/cli/editor_bridge_cli.py debugger output --max-lines 50
```

**How it works:** one persistent DAP client (a core `DapSession` node) owns the TCP connection to the engine's `network/debug_adapter` (port 6006). Commands queue onto it; the matching DAP response is written back to the mailbox. The session idles with a `threads` keepalive every ~4 s (the engine's server rejects any request >5 s after the last client data).

**Self-healing:** leftover editor breakpoints ride along to every spawned game (`--breakpoints`) and pause it at boot — run `debugger clear-breakpoints` before `scene-play` (or rely on the auto boot-break recover: a game found paused at boot is auto-attached + continued). `launch`/`restart` are process-hygienic (path validation, kill on timeout, second-editor refusal, orphan-game warning) — see Launch & connect.

**Gotchas (engine-verified):**
- Exactly ONE DAP client. A *new* client's `initialize` clears ALL editor breakpoints unless `network/debug_adapter/sync_breakpoints=true` (the core sets it at startup).
- `step-out` has no native DAP request — it sends the classic `out` message through the `godot/put_msg` pass-through (the command name contains a **slash**; the server binds `req_` + command).
- `setBreakpoints` requires an **absolute OS path** on the wire (the server's `is_valid_path()` does `begins_with get_resource_path()`); the client globalizes `res://` internally and keeps `res://` for bookkeeping.
- The game must actually be running for any debuggee-bound request to get a response — against a dead game the command times out (that's a symptom, not a protocol bug).
- Raw DAP events stream via `subscribe debugger`.

## Runtime error / editor paused — seamless handling

When the game hits a **runtime error** (a GDScript exception on the main thread) the Godot editor **pauses** with a stack trace. While paused, the in-game DebugBridge (127.0.0.1:5555) is **silent** (the game loop is frozen), so `game.*` commands fail — reads time out, writes fail fast with the structured `game_paused` refusal (coordinator defer). The bridge turns that failure into an **inline investigation** instead of a bare "unreachable":

- A failed `game.*` command reads the editor's state (`state.json`) and, when it sees `game.running == true` **and** `debugger.breaked == true`, it automatically:
  1. **auto-attaches** to the DAP session (no-op if already attached),
  2. fetches and prints the **paused stack** (top frame first),
  3. prints the **pause reason** + the **engine's error message**,
  4. prints a tail of the **DAP output** (game console context),
  5. prints the exact follow-up commands (`debugger vars` / `eval` / `step-over` to investigate, `debugger continue` or `action scene-stop` to resume).

The pause reason + error text come from the engine's DAP `stopped` event
(`reason` ∈ `paused`/`exception`/`breakpoint`/`step`; for `exception` the
**actual error string** is in `text`). The plugin stores the most recent one in
`state.json` under `debugger.last_stopped` = `{reason, text, at_ms}`, so it's
available without a separate RPC. A single racy `state.json` read can't derail
the report — the read is retried.

**What the LLM should do on a `game.*` failure:**
1. Read the printed report — it already contains the reason, stack, and logs.
2. Investigate with `debugger vars` / `debugger eval '<expr>'` / `debugger stack` (all work while `breaked == true`).
3. Resume with `debugger continue` (or `action scene-stop` to kill the game). Do NOT re-run `scene-play` — the game is paused, not dead.

**Driving UI buttons to reproduce errors:** `game scan-ui --types Button` lists buttons with their path + `center` rect; `game signal <path> pressed` emits `pressed` (reliable, no coordinates) or `game click-node <path>` / `game mouse click X Y`. Example: find "Continue" by text, then `game signal <path> pressed` to trigger the error behind that button.

## Anti-patterns

| Anti-pattern | Why wrong | Do instead |
|---|---|---|
| `godot --headless` | catches nothing, tests nothing | `editor_bridge_cli.py launch` |
| Spawning the godot binary directly | bypasses the bridge contract; a second editor corrupts the shared mailbox | `launch` (sets up log capture + waits for a fresh heartbeat) |
| Assuming a stale "connected" state | liveness was never verified | `ping` — liveness is measured |
| `game.*` without `game ping` | game may not be running | `game ping` first |
| Hardcoded `@Button@N` paths | change every session | `scan-ui` → match by text |
| Re-running `scene-play` when a `game.*` cmd fails | the game is usually **paused**, not dead — the inline report + `state.json` show `breaked` | read the inline report; `debugger continue` to resume |
| `key` without `--release` | key stays held | always `--release` |
| `time-scale 0.0` | doesn't crash, but freezes the game AND stalls the game bridge (its socket-poll Timer ticks in scaled time, so later `game.*` commands time out) | ≥ 0.1 |
| `action editor-restart/close` mid-session | kills the human's session (and the engine's relaunch can fail silently) | only with explicit user OK; to restart use `restart` |
| Expecting a new `class_name` to exist after `scripts-reload` | classes register ONLY on fs scan → the scene silently fails to compile | `action fs-scan --wait` after creating scripts |

## Related

- In-game inspection/control reference: `bridge/skills/debug-bridge/SKILL.md`
- Closed-loop input/telemetry driving: `bridge/skills/drive/SKILL.md`
- Human-edit handoff: `bridge/skills/human-edit/SKILL.md`
