@tool
extends RefCounted

## action.debugger.detach — detach the DAP session (game keeps running).

func execute(_args: Dictionary, ctx) -> Variant:
	var dap_or_err: Variant = ctx.require_dap_attached()
	if dap_or_err is Dictionary:
		return dap_or_err
	var dap = dap_or_err
	if not dap.detach(ctx.current_request_id):
		return ctx.make_error(-32000, "DAP not connected")
	return null  # async
