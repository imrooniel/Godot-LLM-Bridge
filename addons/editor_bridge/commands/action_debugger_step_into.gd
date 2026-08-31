@tool
extends RefCounted

## action.debugger.step_into — step into (DAP `stepIn`). Requires breaked. Async.

func execute(_args: Dictionary, ctx) -> Variant:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	if not dap.attached:
		return ctx.make_error(-32002, "Not attached (run `debugger attach` first)")
	dap.wake()
	if not dap.enqueue(ctx.current_request_id, "stepIn", {"threadId": 1}):
		return ctx.make_error(-32000, "DAP not connected")
	return null  # async
