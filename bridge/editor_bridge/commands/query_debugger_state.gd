@tool
extends RefCounted

## query.debugger.state — DAP session state (synchronous).
## Returns: connected, port, attached, breaked, game_active,
##          breakpoint_count, pending_requests, output_lines_buffered.

func execute(_args: Dictionary, ctx) -> Dictionary:
	var dap_or_err: Variant = ctx.require_dap()
	if dap_or_err is Dictionary:
		return dap_or_err
	var dap = dap_or_err
	return dap.get_state()
