@tool
extends RefCounted

## query.debugger.variables — scopes or variable children (DAP `scopes`/
## `variables`). Requires breaked.
## Args (two modes):
##   {"frame": 0}                          -> scopes of stack frame (ids 0,1,..)
##        => {"scopes": [{name, presentationHint, variablesReference}]}
##        names: Locals / Members / Globals
##   {"ref": <variablesReference>}         -> children of a scope/object ref
##        => {"variables": [{name, value, type?, variablesReference}]}
##        (variablesReference > 0 on a variable = expandable object)
## Async in both modes (variable data may arrive from the debuggee late).

func execute(args: Dictionary, ctx) -> Variant:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	if not dap.attached:
		return ctx.make_error(-32002, "Not attached (run `debugger attach` first)")
	dap.wake()
	if int(args.get("ref", 0)) > 0:
		if not dap.enqueue(ctx.current_request_id, "variables",
				{"variablesReference": int(args.get("ref", 0))}):
			return ctx.make_error(-32000, "DAP not connected")
	elif int(args.get("frame", -1)) >= 0:
		if not dap.enqueue(ctx.current_request_id, "scopes",
				{"frameId": int(args.get("frame", 0)), "threadId": 1}):
			return ctx.make_error(-32000, "DAP not connected")
	else:
		return ctx.make_error(-32602, "Provide {\"frame\": N} or {\"ref\": <variablesReference>}")
	return null  # async
