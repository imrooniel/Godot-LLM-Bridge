@tool
extends RefCounted

## action.debugger.step_over — step over (DAP `next`). Requires breaked. Async.

const _DapControl := preload("res://bridge/editor_bridge/commands/_dap_control.gd")


func execute(_args: Dictionary, ctx) -> Variant:
	return _DapControl.run("step_over", ctx)
