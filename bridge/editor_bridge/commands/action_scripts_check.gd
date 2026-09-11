@tool
extends RefCounted

## action.scripts.check — compile-check res:// scripts in the editor.
## The first-class pre-flight for the edit -> run-script loop (dogfood BD-013).
##
##   {"paths": ["res://scripts/foo.gd"]}
##
## Fresh-loads each path (CACHE_MODE_IGNORE — always on-disk) and reports
## OK / a load failure / a parse error (exact message read from the shared
## log collector, the same source run-script uses). Non-mutating: it never
## instantiates the script, so side-effect-free and safe to run any time.
## Returns {ok, results: {path: "OK" | "<error>"}, failed: [paths...]} —
## ok is false if ANY path fails to compile.

func execute(args: Dictionary, ctx) -> Dictionary:
	var paths: Array = args.get("paths", [])
	if paths.is_empty():
		return ctx.make_error(-32602, "scripts-check: 'paths' (array of res:// .gd) required")
	var results: Dictionary = {}
	var failed: Array = []
	for p: Variant in paths:
		var path := str(p)
		if not path.begins_with("res://") or not path.ends_with(".gd"):
			results[path] = "BAD PATH (must be res://*.gd)"
			failed.append(path)
			continue
		if not ResourceLoader.exists(path):
			results[path] = "NOT FOUND"
			failed.append(path)
			continue
		var base: int = _parser_error_index(ctx)
		var s: GDScript = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if s == null:
			results[path] = "LOAD FAILED (check editor logs)"
			failed.append(path)
			continue
		# can_instantiate() is false for non-@tool scripts inside the editor
		# even when they compile fine (a bridge_contract.gd is exactly that),
		# so it is NOT a valid parse gate. reload() IS the parse check (the
		# same primitive action.script.run uses for its @tool-injected copy).
		if s.reload() != OK:
			var err := _recent_parser_error(ctx, base)
			var msg := "PARSE ERROR: " + err if err != "" \
					else "PARSE ERROR (see editor Output panel)"
			results[path] = msg
			failed.append(path)
		else:
			results[path] = "OK"
	return {"ok": failed.is_empty(), "results": results, "failed": failed}


## Index (in the collector buffer) of the most recent parser line, or -1.
## Used to mark the position BEFORE a load/reload so only lines added after
## it can be attributed to THIS file (a stale or interleaved parse line must
## not be mis-attributed on a multi-path call). Mirrors action_script_run.gd.
func _parser_error_index(ctx) -> int:
	var collector = ctx.log_collector if ctx else null
	if collector == null or not collector.has_method("get_messages"):
		return -1
	var messages: Array = collector.get_messages()
	for i in range(messages.size() - 1, -1, -1):
		if str(messages[i]).find("GDScript::reload") != -1:
			return i
	return -1


## Pull the most recent parser error recorded AFTER `base_index`. The engine
## records a failed compile as:  [ts] GDScript::reload (res://<path>.gd:<line>) <parser message>
## We strip the "(res://<path>.gd:<line>)" location so the result is the parser
## message (the offending line + what is expected). Returns "" when there is
## no new error (clean run) or the collector is unavailable.
func _recent_parser_error(ctx, base_index: int) -> String:
	var collector = ctx.log_collector if ctx else null
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
