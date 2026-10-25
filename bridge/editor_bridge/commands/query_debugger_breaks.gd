@tool
extends RefCounted

## query.debugger.breaks — local breakpoint bookkeeping (synchronous).
## Returns: {"breakpoints": {"res://file.gd": {"12": true}}, "count": N}

func execute(_args: Dictionary, ctx) -> Dictionary:
	var dap_or_err: Variant = ctx.require_dap()
	if dap_or_err is Dictionary:
		return dap_or_err
	var dap = dap_or_err
	var all: Dictionary = dap.get_breakpoints()
	var count: int = 0
	for file: Variant in all:
		count += (all[file] as Dictionary).size()
	return {"ok": true, "breakpoints": all, "count": count}
