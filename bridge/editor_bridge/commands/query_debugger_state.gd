@tool
extends RefCounted

## query.debugger.state — DAP session state (synchronous).
## Returns: connected, port, attached, breaked, game_active,
##          breakpoint_count, pending_requests, output_lines_buffered.

func execute(_args: Dictionary, ctx) -> Dictionary:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	return dap.get_state()
