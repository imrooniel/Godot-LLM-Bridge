@tool
extends RefCounted

## query.scene.tree — node tree of an OPEN scene.
## Args: {"path": "res://scenes/combat.tscn", "depth": 3}

func execute(args: Dictionary, ctx) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var depth: int = int(args.get("depth", 3))

	var ei = ctx.editor_interface
	if not ei.get_open_scenes().has(path):
		return ctx.make_error(-32602, "Scene not open: " + path)
	var root: Node = ei.get_edited_scene_root()
	if not root:
		return ctx.make_error(-32602, "Scene root not found")

	return {"ok": true, "path": path, "tree": _build_tree_node(root, depth)}


func _build_tree_node(node: Node, remaining: int) -> Dictionary:
	var result: Dictionary = {"name": node.name, "type": node.get_class()}
	if remaining > 0:
		var children: Array = []
		for child in node.get_children():
			children.append(_build_tree_node(child, remaining - 1))
		if not children.is_empty():
			result["children"] = children
	return result
