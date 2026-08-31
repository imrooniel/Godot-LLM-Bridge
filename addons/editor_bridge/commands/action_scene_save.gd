@tool
extends RefCounted

## action.scene.save — save the current scene.
## Args: {"path": ""} (optional; must equal the current scene)

func execute(args: Dictionary, ctx) -> Dictionary:
	var ei = ctx.editor_interface
	var current_root: Node = ei.get_edited_scene_root()
	if not current_root:
		return ctx.make_error(-32602, "No current scene to save")
	var current: String = current_root.scene_file_path
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		path = current
	if path != current:
		return ctx.make_error(-32602, "Can only save the current scene (current: %s, requested: %s)" % [current, path])
	ei.save_scene()
	return {"ok": true, "scene": path}
