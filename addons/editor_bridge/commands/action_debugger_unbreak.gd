@tool
extends RefCounted

## action.debugger.unbreak — remove one breakpoint (auto-attaches when needed).
## Args: {"file": "res://path/to/script.gd", "line": 12}
## DAP semantics: per-source replace — sends the remaining lines (possibly
## an empty list, which clears the file's breakpoints).

func execute(args: Dictionary, ctx) -> Variant:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	var file: String = str(args.get("file", ""))
	var line: int = int(args.get("line", 0))
	if file.is_empty() or line <= 0:
		return ctx.make_error(-32602, "file (res:// path) and line required")

	var all: Dictionary = dap.get_breakpoints()
	var existing: Dictionary = all.get(file, {})
	if not existing.has(line):
		return {"ok": true, "file": file, "line": line, "note": "was not set",
				"breakpoints": all}
	var lines: Array = existing.keys()
	lines.erase(line)
	lines.sort()

	var bps: Array = []
	for l: Variant in lines:
		bps.append({"line": l})
	var bp_item: Dictionary = {
		"id": ctx.current_request_id,
		"command": "setBreakpoints",
		"args": {
			"source": {"path": file},
			"breakpoints": bps,
		},
		"file": file,
	}
	dap.wake()
	if dap.attached:
		if not dap.set_breakpoints(ctx.current_request_id, file, lines):
			return ctx.make_error(-32000, "DAP not connected")
	else:
		if not dap.attach(ctx.current_request_id, bp_item):
			return ctx.make_error(-32000, "DAP not connected (port %d)" % dap.port)
	return null  # async
