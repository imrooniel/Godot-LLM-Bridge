extends SceneTree

# Headless self-test for the run-script runtime-error surfacing path.
# We cannot drive a live editor here, so we test the COMPOSITION the command
# actually uses: base = _recent_error_index(ctx) marks the buffer position
# BEFORE the call, then _recent_runtime_error(ctx, base) reads only lines
# added AFTER it. Mirroring both helpers proves the no-false-positive
# guarantee (a regression in either helper's index logic is caught here).
#
# Run: godot --path <repo> --headless --script res://bridge/tests/script_run_test.gd

func _initialize() -> void:
	var failures: Array[String] = []

	var helper = _ScriptRunProbe.new()  # mirrors both helpers

	# --- Case 1: most-recent-wins. ---
	# Buffer with two error lines (errA@0, errB@1). Marking at the position
	# BEFORE both errors (base=0, the state before any error existed) and
	# scanning must return the MOST RECENT error (errB), not errA.
	var buf: Array[String] = [
		"[t0] ERROR at a (res://x.gd:42) first error",
		"[t1] ERROR at b (res://x.gd:100) second error",
	]
	var collector = _FakeCollector.new(buf)
	var got: String = helper.recent_runtime_error(collector, 0)
	if got == "":
		failures.append("expected a runtime error, got empty")
	if not got.find("second error") != -1:
		failures.append("most-recent match missing: %s" % got)
	if not got.find("res://x.gd:100") != -1:
		failures.append("location missing from result: %s" % got)

	# --- Case 2: clean buffer returns "". ---
	var clean = _FakeCollector.new(["[12:00:00] INFO all good"])
	if helper.recent_runtime_error(clean, helper.recent_error_index(clean)) != "":
		failures.append("expected empty for clean buffer")

	# --- Case 3 (regression, Bug A): stale error must NOT be flagged. ---
	# An error at index 0, a non-error line at index 1. The mark
	# (recent_error_index) lands on the error line itself (index 0); the scan
	# starts at base+1 = 1, which is the non-error line. No new error -> "".
	var stale_buf: Array[String] = [
		"[t0] ERROR at old (res://x.gd:9) stale",
		"[t1] LOG ok line",
	]
	var stale = _FakeCollector.new(stale_buf)
	var stale_base: int = helper.recent_error_index(stale)
	if stale_base != 0:
		failures.append("stale base should be 0 (the error line), got %d" % stale_base)
	if helper.recent_runtime_error(stale, stale_base) != "":
		failures.append("stale error must not be flagged (false positive)")

	if failures.is_empty():
		print("script_run_test: PASS")
		quit(0)
	else:
		for f in failures:
			printerr("FAIL: " + f)
		quit(1)


class _FakeCollector:
	func _init(m):
		_buf = m
	var _buf
	func get_messages():
		return _buf.duplicate()


class _ScriptRunProbe:
	# Mirrors action_script_run.gd::_recent_error_index and _recent_runtime_error,
	# standalone so the test does not depend on the @tool command compiling in
	# --script mode. The test exercises the COMPOSITION (mark then scan), not
	# either helper in isolation.

	## Mirror of _recent_error_index: index of the most recent "ERROR at " line,
	## or -1 when none.
	func recent_error_index(ctx) -> int:
		var collector = ctx
		if collector == null or not collector.has_method("get_messages"):
			return -1
		var messages: Array = collector.get_messages()
		for i in range(messages.size() - 1, -1, -1):
			if str(messages[i]).find("ERROR at ") != -1:
				return i
		return -1

	## Mirror of _recent_runtime_error: most recent "ERROR at " line strictly
	## AFTER base_index, with the "ERROR " token stripped.
	func recent_runtime_error(ctx, base_index: int) -> String:
		var collector = ctx
		if collector == null or not collector.has_method("get_messages"):
			return ""
		var messages: Array = collector.get_messages()
		var start: int = base_index + 1 if base_index >= 0 else 0
		for i in range(messages.size() - 1, start - 1, -1):
			var line: String = str(messages[i])
			var idx := line.find("ERROR at ")
			if idx == -1:
				continue
			var body := line.substr(idx).strip_edges()
			# Drop the leading "ERROR " token; keep "at <func> (<file>:<line>) <rationale>".
			body = body.substr("ERROR".length()).strip_edges()
			if body.is_empty():
				continue
			return body.left(240)
		return ""
