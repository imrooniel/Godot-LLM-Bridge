@tool
extends RefCounted

## action.script.run — run a method on a project script IN THE EDITOR.
##
##   {"path": "res://scripts/tools/my_scene_builder.gd",
##    "method": "build", "args": ["optional", "strings"]}
##
## The safe scene-generation channel (BD-007): the code executes from a
## normal repo file (git-reviewable, code-reviewed, no arbitrary string),
## instantiated fresh per call with ResourceLoader.CACHE_MODE_IGNORE —
## always the on-disk version, no editor restart, nothing cached, freed
## after the call. Builders that create .tscn/.tres must still finish with
## `action fs-scan` so the editor sees new resources.
##
## Not for eval: the script must exist under res:// and end in .gd.


func execute(args: Dictionary, _ctx) -> Dictionary:
	var path := str(args.get("path", ""))
	var method := str(args.get("method", ""))
	var call_args: Array = args.get("args", []) as Array
	if not path.begins_with("res://") or not path.ends_with(".gd"):
		return {"ok": false, "error": {"code": -32602,
				"message": "run-script: path must be a res:// project script (*.gd)"}}
	if not method.is_valid_identifier():
		return {"ok": false, "error": {"code": -32602,
				"message": "run-script: 'method' must be a valid identifier"}}
	if not ResourceLoader.exists(path):
		return {"ok": false, "error": {"code": -32602,
				"message": "run-script: script not found: %s" % path}}
	var script: GDScript = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	# Non-@tool scripts compile but CANNOT instantiate inside the editor
	# (can_instantiate() == false). Fallback: compile from source with
	# @tool injected — resource_path then stays empty, so scripts that
	# load relatives of their own path must use absolute res:// paths.
	if script == null or not script.is_tool():
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			return {"ok": false, "error": {"code": -32000,
					"message": "run-script: %s failed to load/compile in the editor" % path}}
		var injected := GDScript.new()
		injected.source_code = text if text.begins_with("@tool") else "@tool\n" + text
		if injected.reload() != OK:
			# The engine logs the exact parser error synchronously during the
			# failed reload() (ERR GDScript::reload: ... Parse Error: ...). Read
			# it back from the shared log collector (BD-008 uses the same
			# collector) so the message names the offending line + what is
			# expected, instead of the old opaque "see Output panel".
			return {"ok": false, "error": {"code": -32000,
					"message": _compile_error_message(path, _recent_parser_error(_ctx))}}
		script = injected
	var inst: Object = script.new()
	if inst == null:
		return {"ok": false, "error": {"code": -32000,
				"message": "run-script: %s.new() failed (abstract?)" % path}}
	if not inst.has_method(method):
		return {"ok": false, "error": {"code": -32000,
				"message": "run-script: no method '%s' on %s" % [method, path]}}
	var base: int = _recent_error_index(_ctx)
	var result: Variant = inst.callv(method, call_args)
	inst = null  # drop so the IGNORE-loaded script can be released
	# A GDScript runtime exception inside the invoked method is swallowed by
	# callv() and only lands in the editor log (see _recent_runtime_error for
	# the format). We mark the buffer position BEFORE the call and read only
	# lines added AFTER it, so a stale error from an earlier run-script call
	# cannot be mis-attributed to THIS one (dogfood BD-018: a builder that
	# threw mid-run silently produced a PARTIAL scene; that must be an error,
	# never a silent ok:true).
	var runtime_error: String = _recent_runtime_error(_ctx, base)
	if runtime_error != "":
		# Build the message with plain string concatenation, NOT the `%` operator.
		# runtime_error is engine log text (a multi-line backtrace) that can
		# legitimately contain a literal '%' (e.g. a rationale like "100% match").
		# The `%` operator is a format function that re-parses its arguments'
		# specifiers, so a stray '%' in the inserted value can trip the engine's
		# "String formatting error: not all arguments converted" on the throw
		# path. Concatenation is immune: it never interprets '%' in its operands.
		var error: Dictionary = {
			"code": -32004,
			"message": ("run-script: " + path + ":" + method + " threw a runtime error — "
					+ runtime_error
					+ " (did NOT complete; side effects before the throw may have "
					+ "produced a PARTIAL scene — verify with action fs-scan)"),
			"reason": "logic_error",
			"suggested": ["fix the script and re-run",
				"action fs-scan (if the script writes resources before the throw)"],
		}
		return {"ok": false, "error": error}
	return {"ok": true, "ran": "%s:%s" % [path, method], "result": _serialize(result)}


## JSON-safe projection: basics pass through, everything else stringifies.
func _serialize(value: Variant) -> Variant:
	if typeof(value) in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING]:
		return value
	match typeof(value):
		TYPE_ARRAY:
			var out: Array = []
			for item: Variant in value:
				out.append(_serialize(item))
			return out
		TYPE_DICTIONARY:
			var od: Dictionary = {}
			for key: Variant in value.keys():
				od[str(key)] = _serialize(value[key])
			return od
		_:
			return str(value)


## Assemble the run-script compile-failure message. When the engine logged a
## parser line we surface it inline (line + what is expected); otherwise fall
## back to the Output-panel pointer. The %s is applied to the WHOLE message
## (a single format string) so the path always substitutes — the old template
## had the %s in one string constant and the format operand bound to a sibling
## constant with no placeholder, so the path was dropped and a literal %s
## leaked into the error (dogfood BD-013).
func _compile_error_message(path: String, detail: String) -> String:
	if detail != "":
		return "run-script: %s failed to compile in the editor — %s" % [path, detail]
	return ("run-script: %s failed to compile in the editor "
			+ "(exact parser message in the editor Output panel)") % path


## Pull the most recent GDScript parse error from the shared log collector.
## The engine emits it synchronously during the failed reload(), and the
## collector records it as (see LogCollector._log_error):
##   [ts] ERROR at GDScript::reload (gdscript://<id>.gd:<line>) <parser message>
##   [ts] ERROR at GDScript::reload (res://<path>.gd:<line>)   <parser message>
## We strip the "at GDScript::reload" prefix and the parenthesized location so
## the result reads "<line> <parser message>" (the offending line + what is
## expected) instead of the engine's internal URL. Returns "" when nothing
## recent matches (collector unavailable / no matching line).
func _recent_parser_error(_ctx) -> String:
	# _ctx is a BridgeContext (RefCounted); .log_collector is the shared Logger.
	var collector: Variant = _ctx.log_collector if _ctx else null
	if collector == null or not collector.has_method("get_messages"):
		return ""
	var messages: Array = collector.get_messages()
	for i in range(messages.size() - 1, -1, -1):
		var line: String = str(messages[i])
		var idx := line.find("GDScript::reload")
		if idx == -1:
			continue
		# Everything after "…GDScript::reload" is the message body.
		var body := line.substr(idx).strip_edges()
		if body.is_empty():
			continue
		# Peel off the leading "(" location — drop through to its matching ")".
		var open_paren := body.find("(")
		if open_paren == 0:
			var close_paren := body.find(")")
			if close_paren != -1:
				body = body.substr(close_paren + 1).strip_edges()
		return body.left(240)
	return ""


## Index (in the collector buffer) of the most recent runtime-error line, or
## -1 when none. Used to mark the position BEFORE a callv so that only lines
## added AFTER the call can be attributed to it (a stale error from a prior
## run-script call must not flag a clean run).
##
## The collector (log_collector.gd::_log_error) records a GDScript runtime
## error as:  [ts] ERROR at <func> (<file>:<line>) <rationale><backtrace>
## We match "ERROR at " (the collector format) to find error lines.
func _recent_error_index(_ctx) -> int:
	var collector: Variant = _ctx.log_collector if _ctx else null
	if collector == null or not collector.has_method("get_messages"):
		return -1
	var messages: Array = collector.get_messages()
	for i in range(messages.size() - 1, -1, -1):
		if str(messages[i]).find("ERROR at ") != -1:
			return i
	return -1


## Pull the most recent GDScript RUNTIME error recorded in the collector
## strictly AFTER `base_index`. A throw inside the invoked method is recorded
## (via log_collector.gd::_log_error) as:
##   [ts] ERROR at <func> (<file>:<line>) <rationale><backtrace>
## We keep the "at <func> (<file>:<line>)" location and the rationale so the
## message names WHERE it threw. The rationale (e.g. "Invalid assignment of
## index '5'...") is included when the engine provides it; when it is empty
## (common for GDScript runtime errors) the location alone still identifies
## the throw. Returns "" when there is no new error (clean run) or the
## collector is unavailable.
func _recent_runtime_error(_ctx, base_index: int) -> String:
	var collector: Variant = _ctx.log_collector if _ctx else null
	if collector == null or not collector.has_method("get_messages"):
		return ""
	var messages: Array = collector.get_messages()
	var start: int = base_index + 1 if base_index >= 0 else 0
	for i in range(messages.size() - 1, start - 1, -1):
		var line: String = str(messages[i])
		var idx := line.find("ERROR at ")
		if idx == -1:
			continue
		# Everything from "ERROR at " on is the body: "at <func> (<file>:<line>) <rationale>".
		var body := line.substr(idx).strip_edges()
		# Drop the leading "ERROR " token; keep "at <func> (<file>:<line>) <rationale>".
		body = body.substr("ERROR".length()).strip_edges()
		if body.is_empty():
			continue
		return body.left(240)
	return ""
