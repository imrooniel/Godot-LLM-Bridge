extends SceneTree
## Headless test for the DebugBridge autoload's core (non-socket) capabilities:
## held input (Phase 1a), batch read (Phase 1b), telemetry (Phase 2).
##
## We instantiate the debug_bridge script directly (not the project autoload) so
## the test is self-contained and doesn't need to open the TCP server. _ready()
## guards on OS.is_debug_build(), which is true for the editor binary used to run
## tests, so the handlers initialize. The per-frame telemetry sampler (_process)
## is exercised by letting the tree tick a few frames.
##
## Run: godot --headless --script res://tests/test_bridge.gd

var _failures: int = 0
var _passes: int = 0

const HOLD_FORWARD_KEY := 87  # KEY_W
const HOLD_BACK_KEY := 83     # KEY_S
const HOLD_LEFT_KEY := 65     # KEY_A
const HOLD_RIGHT_KEY := 67    # KEY_D


func _initialize() -> void:
	var bridge: Node = load("res://autoloads/debug_bridge.gd").new()
	bridge.name = "DebugBridge"
	root.add_child(bridge)
	await process_frame  # let _ready() run (init handlers + telemetry state)

	# Register the move_* InputMap actions IF the project didn't define them (the
	# official general-purpose bridge ships no game input; the RPG prototype does).
	# This keeps the action-mapping checks self-contained regardless of project.
	_ensure_action("move_forward", HOLD_FORWARD_KEY)
	_ensure_action("move_back", HOLD_BACK_KEY)
	_ensure_action("move_left", HOLD_LEFT_KEY)
	_ensure_action("move_right", HOLD_RIGHT_KEY)

	# ---- Held input (Phase 1a) ------------------------------------------------
	_check("held input: nothing held at start",
			not bridge.is_key_held(HOLD_FORWARD_KEY) and bridge._held_actions.is_empty())
	bridge._cmd_hold_key({"key": "W"})
	_check("held input: KEY_W held after hold_key", bridge.is_key_held(HOLD_FORWARD_KEY))
	_check("held input: move_forward action held after hold W", bridge.is_action_held("move_forward"))
	_check("held input: move_back NOT held after hold W", not bridge.is_action_held("move_back"))
	bridge._cmd_release_key({"key": "W"})
	_check("held input: KEY_W released", not bridge.is_key_held(HOLD_FORWARD_KEY))
	_check("held input: move_forward released", not bridge.is_action_held("move_forward"))

	# Multiple keys + an unknown key.
	bridge._cmd_hold_key({"key": "S"})
	bridge._cmd_hold_key({"key": "A"})
	_check("held input: move_back held after hold S", bridge.is_action_held("move_back"))
	_check("held input: move_left held after hold A", bridge.is_action_held("move_left"))
	var unknown: Dictionary = bridge._cmd_hold_key({"key": "NOT_A_KEY"})
	_check("held input: unknown key returns an error envelope", "error" in unknown)
	bridge._cmd_release_key({"key": "S"})
	bridge._cmd_release_key({"key": "A"})

	# ---- Batch read (Phase 1b) ------------------------------------------------
	var batch: Dictionary = bridge._cmd_batch_get({"items": [
		{"path": ".", "prop": "name"},
		{"path": ".", "prop": "definitely_not_a_property"},
		{"path": "does_not_exist_xyz", "prop": "name"},
	]})
	var bitems: Array = batch.get("result", {}).get("items", [])
	_check("batch_get: returns 3 items", bitems.size() == 3)
	_check("batch_get: valid item has value == node name",
			bitems.size() > 0 and bitems[0].get("value") == "root")
	_check("batch_get: bad property -> per-item error, not abort",
			bitems.size() > 1 and "error" in bitems[1] and bitems[1].get("prop") == "definitely_not_a_property")
	_check("batch_get: bad node -> per-item error, not abort",
			bitems.size() > 2 and "error" in bitems[2])
	var empty: Dictionary = bridge._cmd_batch_get({"items": []})
	_check("batch_get: empty items -> error envelope", "error" in empty)

	# ---- Telemetry (Phase 2) --------------------------------------------------
	# Resolve a real node (root) and sample one of its readable props. hz=30 makes
	# the frame-counter step 1 at 60fps, so the buffer fills over the next frames.
	var tstart: Dictionary = bridge._cmd_telemetry_start({"hz": 30.0, "nodes": [
		{"path": ".", "props": ["name"]},
	]})
	_check("telemetry: start reports ok", tstart.get("result", {}).get("ok") == true)
	_check("telemetry: frame_step >= 1", tstart.get("result", {}).get("frame_step", 0) >= 1)
	# Let the tree run several frames so the frame-counter-gated sampler appends.
	for i in range(12):
		await process_frame
	_check("telemetry: ring buffer accumulated samples", bridge._telemetry_buf.size() > 0)
	var sample: Dictionary = bridge._cmd_telemetry_sample({})
	var samples: Array = sample.get("result", {}).get("samples", [])
	_check("telemetry: sample returns running samples",
			sample.get("result", {}).get("running") == true and samples.size() > 0)
	_check("telemetry: sample records node 'root' with 'name'",
			samples.size() > 0 and samples[0].get("values", {}).has("root"))
	# limit
	var lim: Dictionary = bridge._cmd_telemetry_sample({"limit": 1})
	_check("telemetry: limit=1 returns exactly 1",
			lim.get("result", {}).get("samples", []).size() == 1)
	var stop: Dictionary = bridge._cmd_telemetry_stop({})
	_check("telemetry: stop reports ok", stop.get("result", {}).get("ok") == true)
	_check("telemetry: buffer cleared after stop", bridge._telemetry_buf.is_empty())
	var no_run: Dictionary = bridge._cmd_telemetry_sample({})
	_check("telemetry: sample while not running -> error", "error" in no_run)

	bridge.queue_free()

	print("")
	print("=== Bridge Test Results ===")
	print("Passed: %d" % _passes)
	print("Failed: %d" % _failures)
	if _failures == 0:
		print("ALL TESTS PASSED")
	else:
		print("TESTS FAILED")
	quit(1 if _failures > 0 else 0)


## Add a key to an InputMap action at runtime (no-op if the action already maps
## this key). Used so the action-mapping checks run even in a project whose
## project.godot defines no game input (the official bridge).
func _ensure_action(action: String, keycode: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = true
	InputMap.action_add_event(action, ev)


func _check(label: String, condition: bool) -> void:
	if condition:
		_passes += 1
		print("  PASS: %s" % label)
	else:
		_failures += 1
		print("  FAIL: %s" % label)
