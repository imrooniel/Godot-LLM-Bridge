@tool
extends RefCounted

## query.debugger.output — buffered game output captured from DAP `output`
## events (synchronous). Args: {"from": 0, "max_lines": 200}
## Note: DAP output requires an attached session; without one use
## `logs get --source panel` (editor Output panel) instead.

func execute(args: Dictionary, ctx) -> Dictionary:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	var from_index: int = maxi(0, int(args.get("from", 0)))
	var max_lines: int = maxi(1, int(args.get("max_lines", 200)))
	var total: int = dap.output_lines.size()
	var slice: Array = dap.output_lines.slice(from_index, mini(from_index + max_lines, total))
	return {
		"ok": true,
		"messages": slice,
		"total_lines": total,
		"from": from_index,
		"count": slice.size(),
		"attached": dap.attached,
	}
