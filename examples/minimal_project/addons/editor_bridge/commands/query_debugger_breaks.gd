@tool
extends RefCounted

## query.debugger.breaks — local breakpoint bookkeeping (synchronous).
## Returns: {"breakpoints": {"res://file.gd": {"12": true}}, "count": N}

func execute(_args: Dictionary, ctx) -> Dictionary:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	var all: Dictionary = dap.get_breakpoints()
	var count: int = 0
	for file: Variant in all:
		count += (all[file] as Dictionary).size()
	return {"ok": true, "breakpoints": all, "count": count}
