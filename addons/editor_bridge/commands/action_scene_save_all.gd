@tool
extends RefCounted

## action.scene.save_all — save all open scenes.

func execute(_args: Dictionary, ctx) -> Dictionary:
	var ei = ctx.editor_interface
	ei.save_all_scenes()
	return {"ok": true, "count": ei.get_open_scenes().size()}
