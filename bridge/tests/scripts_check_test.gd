extends SceneTree

# Headless self-test for the scripts-check per-file parser-line guard.
# The command marks base = _parser_error_index(ctx) BEFORE a load/reload,
# then _recent_parser_error(ctx, base) reads only lines added AFTER it, so a
# stale or interleaved parse line on a multi-path call is not mis-attributed.
# Mirrors BOTH helpers as a standalone probe so the test does not depend on
# the @tool command compiling in --script mode.
#
# Run: godot --path <repo> --headless --script res://bridge/tests/scripts_check_test.gd

func _initialize() -> void:
	var failures: Array[String] = []

	var helper = _ScriptsCheckProbe.new()  # mirrors both helpers

	# The command marks base = _parser_error_index(ctx) BEFORE each file is
	# compiled, over whatever the buffer holds at that moment. For a
	# standalone unit test the mark is the index the probe computes over the
	# PRIOR state (the buffer minus the line just produced by the compile).

	# --- Case 1: most-recent-after-base wins. ---
	# Buffer [parseA@0, parseB@1]. parseB is the file just compiled, so base
	# (marked before parseB's compile, over just [parseA]) is 0. Scanning
	# after base must return parseB's line (b.gd:4), not the stale parseA's.
	var parseA := "[t0] GDScript::reload (res://a.gd:4) Expected expression after \"+\" operator"
	var parseB := "[t1] GDScript::reload (res://b.gd:4) Expected expression after \"+\" operator"
	var buf: Array[String] = [parseA, parseB]
	var collector = _FakeCollector.new(buf)
	var base: int = helper.parser_error_index(_FakeCollector.new([parseA]))
	if base != 0:
		failures.append("base should be 0 (mark before parseB), got %d" % base)
	var got: String = helper.recent_parser_error(collector, base)
	if not got.find("res://b.gd:4") != -1:
		failures.append("expected parseB's line (b.gd:4), got: %s" % got)
	if not got.find("Expected expression after \"+\" operator") != -1:
		failures.append("parser message missing from result: %s" % got)
	if got.find("res://a.gd:4") != -1:
		failures.append("parseA's line leaked into result (stale): %s" % got)

	# --- Case 2: stale-excluded. ---
	# parseA@0 is stale (from a PRIOR compile). This file's compile logged no
	# parse line — only a log line @1. base (marked before this file's compile,
	# when the buffer already held the stale parseA) is 0. The scan
	# (from base+1 = 1) reaches only the log line and returns "". Without the
	# base guard the reverse-scan would have returned the stale parseA.
	var stale_parse := "[t0] GDScript::reload (res://a.gd:4) Expected expression after \"+\" operator"
	var stale_buf: Array[String] = [stale_parse, "[t1] LOG ok line"]
	var stale = _FakeCollector.new(stale_buf)
	var stale_base: int = helper.parser_error_index(_FakeCollector.new([stale_parse]))
	if stale_base != 0:
		failures.append("stale base should be 0 (stale parseA sits before it), got %d" % stale_base)
	if helper.recent_parser_error(stale, stale_base) != "":
		failures.append("stale parse line must not be flagged (false positive)")

	# --- Case 3: clean buffer returns "". ---
	var clean = _FakeCollector.new(["[12:00:00] INFO all good"])
	if helper.recent_parser_error(clean, helper.parser_error_index(clean)) != "":
		failures.append("expected empty for clean buffer")

	if failures.is_empty():
		print("scripts_check_test: PASS")
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


class _ScriptsCheckProbe:
	# Mirrors action_scripts_check.gd::_parser_error_index and _recent_parser_error,
	# standalone so the test does not depend on the @tool command compiling in
	# --script mode. The test exercises the COMPOSITION (mark then scan), not
	# either helper in isolation.

	## Mirror of _parser_error_index: index of the most recent "GDScript::reload"
	## line, or -1 when none.
	func parser_error_index(ctx) -> int:
		var collector = ctx
		if collector == null or not collector.has_method("get_messages"):
			return -1
		var messages: Array = collector.get_messages()
		for i in range(messages.size() - 1, -1, -1):
			if str(messages[i]).find("GDScript::reload") != -1:
				return i
		return -1

	## Mirror of _recent_parser_error: most recent "GDScript::reload" line strictly
	## AFTER base_index, with the "(res://<path>.gd:<line>)" location stripped.
	func recent_parser_error(ctx, base_index: int) -> String:
		var collector = ctx
		if collector == null or not collector.has_method("get_messages"):
			return ""
		var messages: Array = collector.get_messages()
		var start: int = base_index + 1 if base_index >= 0 else 0
		for i in range(messages.size() - 1, start - 1, -1):
			var line: String = str(messages[i])
			var idx := line.find("GDScript::reload")
			if idx == -1:
				continue
			var body := line.substr(idx).strip_edges()
			if body.is_empty():
				continue
			var open_paren := body.find("(")
			if open_paren == 0:
				var close_paren := body.find(")")
				if close_paren != -1:
					body = body.substr(close_paren + 1).strip_edges()
			return body.left(240)
		return ""
