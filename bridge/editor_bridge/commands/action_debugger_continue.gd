@tool
extends RefCounted

## action.debugger.continue — resume execution (DAP `continue`). Async.

const _DapControl := preload("res://bridge/editor_bridge/commands/_dap_control.gd")


func execute(_args: Dictionary, ctx) -> Variant:
	return _DapControl.run("continue", ctx)
