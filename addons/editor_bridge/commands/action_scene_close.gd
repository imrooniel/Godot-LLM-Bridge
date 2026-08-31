@tool
extends RefCounted

## action.scene.close — close the current scene.
## EditorInterface has no close-by-path API (close_scene() only), so if
## 'path' is given it must match the currently edited scene.
## Args: {"path": ""} (optional; must equal the current scene)

func execute(args: Dictionary, ctx) -> Dictionary:
	var ei = ctx.editor_interface
	var current_root: Node = ei.get_edited_scene_root()
	var current: String = current_root.scene_file_path if current_root else ""
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		path = current
	if path.is_empty():
		return ctx.make_error(-32602, "No scene open")
	if path != current:
		return ctx.make_error(-32602, "Can only close the current scene (current: %s, requested: %s)" % [current, path])
	ei.close_scene()
	return {"ok": true, "scene": path}
