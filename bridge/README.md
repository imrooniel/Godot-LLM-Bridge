# Godot LLM Bridge

A file-mailbox bridge between the Godot editor and runtime and external CLI tools / LLMs, for
programmatic game-state inspection, input driving, and real DAP debugging.

This folder is **fully generic** — it contains no game-specific code. It is self-contained and
portable: drop it into any Godot 4 project and register the autoload.

## Layout
- `autoloads/` — `debug_bridge.gd` (the in-game channel, one autoload) + `debug_log_collector.gd`.
- `editor_bridge/` — the `@tool` editor addon: the mailbox server, DAP session, game proxy, and
  `commands/` (each command is a script located by name).
- `human_edit/` — the `@tool` editor plugin that captures a human's editor edits as content deltas.
- `contract/` — `bridge_contract.gd`: the single shared definition of the response envelope.
- `tests/` — headless self-tests (`bridge_contract_test.gd`, `human_edit_test.gd`).
- `cli/` — `editor_bridge_cli.py`: the command-line front-end the LLM/human use to drive the bridge.
- `skills/` — agent skill docs (debug-bridge, editor-bridge, drive, human-edit).
- `game/` — **how to hook in your own game**: `GUIDE.md` (the contract) + `example/` (worked sample).

## Install (1 line)
```
[autoload]
DebugBridge="*res://bridge/autoloads/debug_bridge.gd"
```
Enable the two editor plugins in `project.godot` `[editor_plugins]`:
```
res://bridge/editor_bridge/plugin.cfg
res://bridge/human_edit/plugin.cfg
```

## Then hook in your game
See `game/GUIDE.md`. The short version: define an `[input]` action map, OR `DebugBridge.is_action_held`
with `Input.is_action_held` in your movement code, and expose a state-hub autoload the LLM can read.

## Run the self-tests
```
godot --path <repo> --headless --check-only --script res://bridge/autoloads/debug_bridge.gd
godot --path <repo> --headless --script res://bridge/tests/bridge_contract_test.gd
godot --path <repo> --headless --script res://bridge/tests/human_edit_test.gd
```
