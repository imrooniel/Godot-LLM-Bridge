@tool
extends RefCounted

## action.debugger.clear_breakpoints — clear ALL editor-side breakpoints: the
## exact set the engine bakes into every spawned game via `--breakpoints`
## (editor_run.cpp:128-142). This is the C8 fix: a leftover editor breakpoint
## pauses every new game at boot (attached=false) and nothing can un-break it.
##
## REVIEW-VERIFIED mechanism (works with NO running game — the original draft
## read the DAP bookkeeping, which is empty when no game is attached, and
## required an attach, which needs a running game, so it no-oped in exactly the
## state it must fix):
##   1. ENUMERATE the editor's REAL breakpoints synchronously via the BOUND
##      `EditorInterface.get_script_editor().get_breakpoints()`
##      (editor_interface.cpp:893; script_editor_plugin.cpp:4101) -> an Array of
##      "res://path:line" strings covering open tabs AND the closed-script cache
##      (script_editor_plugin.cpp:2287-2321). No game needed.
##   2. CLEAR each file via DAP `setBreakpoints` with an EMPTY list.
##      `req_setBreakpoints` is NOT attach-gated (debug_adapter_parser.cpp:352-389)
##      — it needs only a CONNECTED peer (the persistent DAP singleton; poll()
##      sets `_current_peer` for any live client, debug_adapter_protocol.cpp:1212),
##      no running game. It clears both stores via
##      `update_breakpoints` -> `ScriptEditor::_set_breakpoint(path, line, false)`
##      (script_editor_plugin.cpp:952-984).
##
## Async: returns null; the DAP session (long-lived) owns the connect-wait and
## answers the CLI — a summary on success, an explicit error on connect timeout.
func execute(args: Dictionary, ctx) -> Variant:
	var ei = ctx.editor_interface
	if ei == null:
		return ctx.make_error(-32000, "EditorInterface not available")
	var se = ei.get_script_editor()
	if se == null:
		return {"ok": true, "cleared": 0, "note": "no script editor open; nothing to clear"}
	# 1) Enumerate the editor's real breakpoints (res://path:line strings).
	var raw: Array = se.get_breakpoints()
	if raw.is_empty():
		return {"ok": true, "cleared": 0, "note": "no editor breakpoints; nothing to clear"}
	var files: Dictionary = {}
	var total := 0
	for item in raw:
		var s: String = str(item)
		var cut := s.rfind(":")
		if cut <= 0:
			continue
		var path := s.substr(0, cut)
		if not files.has(path):
			files[path] = []
		files[path].append(s.substr(cut + 1).to_int())
		total += 1
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32000,
			"Found %d editor breakpoint(s) but the DAP session is unavailable — cannot clear."
			% total)
	# 2) Hand off to the DAP session, which is LONG-LIVED and owns the async
	#    connect-wait + the outbox response (see `clear_editor_breakpoints`,
	#    Step 3). We must NOT do the connect-wait here in a closure: this command
	#    instance is transient and may be freed once execute() returns (the core
	#    does not retain async commands), which would dangle the retry.
	dap.clear_editor_breakpoints(files.keys(), ctx.current_request_id)
	return null
