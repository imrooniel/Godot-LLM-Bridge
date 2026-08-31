@tool
extends RefCounted

## action.scene.open — open a scene in the editor.
## Args: {"path": "res://scenes/combat.tscn"}
## (the scene_opened event is emitted by the core's state diff)

func execute(args: Dictionary, ctx) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return ctx.make_error(-32602, "Scene path required")
	ctx.editor_interface.open_scene_from_path(path)
	return {"ok": true, "scene": path}
