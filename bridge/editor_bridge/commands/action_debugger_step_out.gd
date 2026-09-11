@tool
extends RefCounted

## action.debugger.step_out — step out of the current function.
## The DAP adapter has no stepOut request, so this sends the raw classic
## protocol message "out" through the `godot_put_msg` pass-through. Async.

func execute(_args: Dictionary, ctx) -> Variant:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	if not dap.attached:
		return ctx.make_error(-32002, "Not attached (run `debugger attach` first)")
	dap.wake()
	# The server binds "req_" + command; the godot passthrough is bound as
	# "req_godot/put_msg" — the command name contains a SLASH.
	if not dap.enqueue(ctx.current_request_id, "godot/put_msg",
			{"message": "out", "data": []}):
		return ctx.make_error(-32000, "DAP not connected")
	return null  # async
