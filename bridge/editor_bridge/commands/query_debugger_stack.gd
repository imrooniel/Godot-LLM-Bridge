@tool
extends RefCounted

## query.debugger.stack — call stack (DAP `stackTrace`). Requires breaked.
## Async: while the debuggee is still delivering a stack dump the adapter
## defers the response — it arrives when the dump completes.
## Returns body: {"stackFrames": [{id, name, line, column, source: {path}}]}

func execute(_args: Dictionary, ctx) -> Variant:
	var dap_or_err: Variant = ctx.require_dap_attached()
	if dap_or_err is Dictionary:
		return dap_or_err
	var dap = dap_or_err
	dap.wake()
	if not dap.enqueue(ctx.current_request_id, "stackTrace", {"threadId": 1}):
		return ctx.make_error(-32000, "DAP not connected")
	return null  # async
