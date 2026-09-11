# Hooking your game into the Godot LLM Bridge

The bridge (this `bridge/` folder) is a file-mailbox + in-game channel between the Godot
editor/runtime and an external CLI/LLM. It is **fully generic** — it knows nothing about your
game. To make your game *drivable* and *inspectable* by the LLM, your game code must implement a
small, well-defined hook. The JRPG slice in the repo is the **worked example** of these patterns
(see `example/`).

The whole install for the bridge is **one autoload**. Everything below is game-side code you write.

## The 5-step contract

### 1. Register the autoload (the entire bridge install)
In your project's `project.godot`:
```
[autoload]
DebugBridge="*res://bridge/autoloads/debug_bridge.gd"
```
The `*` marks it a **singleton** (a global constant usable as `DebugBridge` from any script).
Enablement is the key's presence.

### 2. Define an `[input]` action map
The LLM drives your game through *named input actions* (`move_up`, `move_left`, `interact`, ...).
Declare them in `project.godot` `[input]`. The CLI's `hold`/`release` drive exactly those actions,
so your normal input code works for both human play and agent-driven play.

### 3. OR the bridge with real input (the movement hook)
This is the canonical hook — let the agent drive your character while the human can still play:
```gdscript
# from example/player.gd
func _physics_process(delta: float) -> void:
    if DebugBridge.is_action_held(action) or Input.is_action_held(action):
        velocity = direction * MOVE_SPEED
```
`DebugBridge.is_action_held(action: String) -> bool` reports whether the LLM is currently holding
that action. `Input.is_action_held` is the human. OR them so either source moves the player.

### 4. Expose a state hub (what makes the game inspectable)
Give the LLM something to read. A small autoload (the state-hub pattern in
`example/game_runtime.gd`) holds flags, party state, the current map, and the spawn point. The LLM
reads it via `game get <state-hub> some_flag`, `game call <state-hub> get_flag name`, or a
`game gd-eval "<state-hub>.some_expr"`. Without a state hub the LLM is *blind* — it can only drive
input, not observe state.

### 5. (Optional) Scene transitions
On overlap with a zone, read the state hub and hand off the spawn, as
`example/transition_zone.gd` does:
```gdscript
# game sets <state-hub>.current_map / <state-hub>.spawn_point on body_entered
```

## Scene builders: make `run-script` success mean verified

The `action run-script res://… <method>` channel runs a repo-script method in the
editor and returns whatever the method returns. The bridge surfaces **runtime
exceptions** as a `logic_error` (a throw mid-run is an error, never a silent success),
so the remaining discipline is to make the builder *self-attesting*:

1. **Build, then assert readbacks, then return a summary.** A builder that adds nodes
   or paints cells should re-read what it wrote before finishing (a silent no-op or
   silent drop — a polygon that stores nothing, a node that doesn't serialize — is
   only caught by reading back). Example:

   ```gdscript
   func build() -> Dictionary:
       # … build the scene …
       var n: int = root.get_child_count()
       var poly_ok: int = _assert_poly_readbacks()   # re-read each cell's polygon count
       if poly_ok == 0:
           push_error("build: no polygons read back — a tile did not store")
           return {"ok": false, "reason": "no polygons", "nodes": n}
       ResourceSaver.save(root, "res://scenes/world/out.tscn")
       return {"ok": true, "nodes": n, "poly_ok": poly_ok}
   ```

2. **End with `action fs-scan`** so the editor sees any new `.tscn`/`.tres`.
3. **Prefer explicit types over `:=` inference** on `get_node_or_null` / `get_tile_data`
   returns in dev builds, and use `load("res://x.gd").new().method()` for cross-script
   calls (`load(…).method()` without `.new()` trips the dev-build compiler).

The bridge's job is to surface the throw; **your** job is the readback assert so a
partial build can't masquerade as a complete one.

## Driving & observing (what the CLI does to your game)
- `game hold <action>` / `game release <action>` — press/release a named action (uses the
  `DebugBridge` held-key mechanism your step-3 hook polls).
- `game held-keys` — report which actions are currently held.
- `game get <node> <prop>` / `game call <node> <method> [args]` — read a property / call a method.
- `game gd-eval "<expr>"` — evaluate one GDScript expression in the running game (autoloads,
  globals, class names resolve).
- `game get-many ...` / `game sample` / `game watch` — batch reads / per-frame telemetry.

## Accessing DebugBridge from untyped contexts
If you can't reference the typed `DebugBridge` global, use the engine singleton:
```gdscript
# from example/npc.gd
_bridge = Engine.get_singleton("DebugBridge")
if _bridge.is_action_held("interact"):
    ...
```

## Running the bridge self-tests
```
godot --path <repo> --headless --script res://bridge/tests/bridge_contract_test.gd
godot --path <repo> --headless --script res://bridge/tests/human_edit_test.gd
```
