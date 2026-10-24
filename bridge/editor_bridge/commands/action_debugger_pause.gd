@tool
extends RefCounted

## action.debugger.pause — pause the running game (DAP `pause`). Async.

const _DapControl := preload("res://bridge/editor_bridge/commands/_dap_control.gd")


func execute(_args: Dictionary, ctx) -> Variant:
	return _DapControl.run("pause", ctx)
