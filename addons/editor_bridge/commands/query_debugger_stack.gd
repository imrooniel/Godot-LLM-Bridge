@tool
extends RefCounted

## query.debugger.stack — call stack (DAP `stackTrace`). Requires breaked.
## Async: while the debuggee is still delivering a stack dump the adapter
## defers the response — it arrives when the dump completes.
## Returns body: {"stackFrames": [{id, name, line, column, source: {path}}]}

func execute(_args: Dictionary, ctx) -> Variant:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	if not dap.attached:
		return ctx.make_error(-32002, "Not attached (run `debugger attach` first)")
	dap.wake()
	if not dap.enqueue(ctx.current_request_id, "stackTrace", {"threadId": 1}):
		return ctx.make_error(-32000, "DAP not connected")
	return null  # async
