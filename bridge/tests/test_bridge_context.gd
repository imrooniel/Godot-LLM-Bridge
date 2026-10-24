extends SceneTree
# Headless self-test: run with
#   godot --path <repo> --headless --script res://bridge/tests/test_bridge_context.gd
# Prints "BRIDGE_CONTEXT_OK" and quits(0) on success; prints the failure and quits(1) on failure.
#
# Verifies BridgeContext.make_error():
#   - back-compat: with no reason/suggested, the error dict is a clean
#     {code, message} (no empty reason/suggested keys).
#   - with reason + suggested provided, they are carried in error.reason / error.suggested.
#   - code is an int (not a string).

func _initialize() -> void:
	var failures: Array[String] = []

	# Load by explicit path (NOT the global class name): in headless `--script`
	# mode the engine does not build the global-class cache, so a bare
	# `BridgeContext` reference would fail to resolve. (Matches bridge_contract_test.gd.)
	var ctx = load("res://bridge/editor_bridge/bridge_context.gd").new()

	# Default: no reason/suggested (back-compat). code is an int.
	var e1 = ctx.make_error(-32603, "editor is not running")
	if not (e1["ok"] == false):
		failures.append("make_error() default: ok should be false -> %s" % str(e1))
	if not (e1["error"]["code"] == -32603):
		failures.append("make_error() default: code should be int -32603 -> %s" % str(e1["error"]))
	if not (e1["error"]["message"] == "editor is not running"):
		failures.append("make_error() default: message mismatch -> %s" % str(e1["error"]))
	if "reason" in e1["error"]:
		failures.append("make_error() default: must not carry a 'reason' key -> %s" % str(e1["error"]))
	if "suggested" in e1["error"]:
		failures.append("make_error() default: must not carry a 'suggested' key -> %s" % str(e1["error"]))

	# With reason + suggested:
	var e2 = ctx.make_error(-32002, "5555 unreachable",
		"game_paused_or_dropped", ["debugger state", "action scene-stop"])
	if not (e2["error"]["reason"] == "game_paused_or_dropped"):
		failures.append("make_error() reason mismatch -> %s" % str(e2["error"]))
	if not (e2["error"]["suggested"] == ["debugger state", "action scene-stop"]):
		failures.append("make_error() suggested mismatch -> %s" % str(e2["error"]))
	if not (e2["error"]["code"] == -32002):
		failures.append("make_error() with reason: code should be int -32002 -> %s" % str(e2["error"]))

	if failures.is_empty():
		print("BRIDGE_CONTEXT_OK")
		quit(0)
	else:
		for f in failures:
			printerr("FAIL: " + f)
		quit(1)
