@tool
extends RefCounted

## action.scene.stop — stop the running game.

func execute(_args: Dictionary, ctx) -> Dictionary:
	var ei = ctx.editor_interface
	if not ei.is_playing_scene():
		return ctx.make_error(-32602, "Nothing is running")
	ei.stop_playing_scene()
	return {"ok": true}
