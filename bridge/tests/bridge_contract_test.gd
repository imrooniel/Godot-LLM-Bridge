extends SceneTree
# Headless self-test: run with
#   godot --path <repo> --headless --script res://bridge/tests/bridge_contract_test.gd
# Prints "PASS" and quits(0) on success; prints the failure and quits(1) on failure.

func _initialize() -> void:
	var failures: Array[String] = []

	# Resolve the contract by explicit path (NOT the global class name). In headless
	# `--script` mode the engine does not build the global-class cache, so a bare
	# `BridgeContract` reference would fail to resolve, and `:=` type-inference from a
	# loaded (untyped) script's method call would fail too. Load by path and use a
	# plain untyped var (matching the sibling `human_edit_test.gd`) so no inference is
	# needed. (In the editor, `editor_bridge.gd` loads the same contract via `preload`.)
	var contract = load("res://bridge/contract/bridge_contract.gd")

	var r1 = contract.ok({ "id": "p1" }, { "game": { "running": true }, "breaked": false })
	if not (r1["ok"] == true and r1["result"] == { "id": "p1" } and r1["state"].has("game")):
		failures.append("ok(): wrong shape -> %s" % str(r1))

	var e1 = contract.err(-32042, "game is paused", "wait",
		["godot-status"], { "breaked": true })
	if not (e1["ok"] == false
			and e1["error"]["code"] == -32042
			and e1["error"]["reason"] == "wait"
			and e1["error"]["suggested"] == ["godot-status"]
			and e1["state"]["breaked"] == true):
		failures.append("err(): wrong shape -> %s" % str(e1))

	var s1 = contract.state_object(false, { "running": true }, true, { "n": 3 })
	if not (s1["godot"] == "game" and s1["breaked"] == true and s1["turn"] == { "n": 3 }):
		failures.append("state_object(): wrong -> %s" % str(s1))

	var s2 = contract.state_object(true, {}, false)
	if not (s2["godot"] == "editor" and s2["editor_running"] == true):
		failures.append("state_object(editor): wrong -> %s" % str(s2))

	var s3 = contract.state_object(false, {}, false)
	if s3["godot"] != "none":
		failures.append("state_object(none): wrong -> %s" % str(s3))

	if not contract.is_transport_error({ "connect_error": true }):
		failures.append("is_transport_error(): should detect")
	if contract.is_transport_error({ "ok": false, "error": { "code": "x" } }):
		failures.append("is_transport_error(): false positive")
	if contract.is_transport_error(null):
		failures.append("is_transport_error(null): false positive")

	if failures.is_empty():
		print("PASS")
		quit(0)
	else:
		for f in failures:
			printerr("FAIL: " + f)
		quit(1)
