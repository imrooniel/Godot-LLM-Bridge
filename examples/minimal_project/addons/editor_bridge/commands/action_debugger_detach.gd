@tool
extends RefCounted

## action.debugger.detach — detach the DAP session (game keeps running).

func execute(_args: Dictionary, ctx) -> Variant:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	if not dap.attached:
		return ctx.make_error(-32002, "Not attached (run `debugger attach` first)")
	if not dap.detach(ctx.current_request_id):
		return ctx.make_error(-32000, "DAP not connected")
	return null  # async
