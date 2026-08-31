@tool
extends RefCounted

## query.scene — metadata for a scene path (open status or resource info).
## Args: {"path": "res://scenes/combat.tscn"}

func execute(args: Dictionary, ctx) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return ctx.make_error(-32602, "Scene path required")

	var ei = ctx.editor_interface
	var open_scenes: Array = ei.get_open_scenes()
	if open_scenes.has(path):
		var root: Node = ei.get_edited_scene_root()
		if root:
			var children: Array = []
			for child in root.get_children():
				children.append({"name": child.name, "type": child.get_class()})
			return {
				"ok": true,
				"path": path,
				"name": root.name,
				"open": true,
				"root_type": root.get_class(),
				"root_children": children,
			}
		return {"ok": true, "path": path, "open": false}

	var scene := ResourceLoader.load(path, "PackedScene")
	if scene:
		return {"ok": true, "path": path, "name": scene.resource_name, "open": false}

	return ctx.make_error(-32602, "Scene not found: " + path)
