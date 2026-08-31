@tool
extends RefCounted

## action.scene.reload — reload an open scene from disk.
## Args: {"path": "res://scenes/combat.tscn"}

func execute(args: Dictionary, ctx) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return ctx.make_error(-32602, "Scene path required")
	ctx.editor_interface.reload_scene_from_path(path)
	return {"ok": true, "scene": path}
