@tool
extends RefCounted

## action.debugger.step_into — step into (DAP `stepIn`). Requires breaked. Async.

const _DapControl := preload("res://bridge/editor_bridge/commands/_dap_control.gd")


func execute(_args: Dictionary, ctx) -> Variant:
	return _DapControl.run("step_into", ctx)
