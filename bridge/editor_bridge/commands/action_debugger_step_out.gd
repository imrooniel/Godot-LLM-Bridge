@tool
extends RefCounted

## action.debugger.step_out — step out of the current function.
## The DAP adapter has no stepOut request, so this sends the raw classic
## protocol message "out" through the `godot_put_msg` pass-through. Async.
## (The pass-through command name contains a SLASH: `godot/put_msg`.)

const _DapControl := preload("res://bridge/editor_bridge/commands/_dap_control.gd")


func execute(_args: Dictionary, ctx) -> Variant:
	return _DapControl.run("step_out", ctx)
