@tool
extends RefCounted

## query.human.deltas — read buffered human editor content deltas (spec C4).
##
## Args: {"since": "<turn_id>"} (empty = all buffered).
##
## The HumanEdit plugin (addons/human_edit) buffers the deltas. In Godot 4.x
## EditorPlugin IS a Node, but it is parented under the editor's @EditorNode —
## it is NOT a direct root child. (Verified live: the tree search found it at
## root/@EditorNode@.../@EditorPlugin@...; the root's own children are only
## @EditorNode/@ProgressDialog/@Timer.) So the plan's "scan root.get_children()"
## would find nothing; we do a tree-wide search under ctx.tree.root for the node
## carrying get_deltas() instead. The command and the plugin share the single
## editor process and SceneTree, so the found node's buffer is live.
func execute(args: Dictionary, ctx) -> Dictionary:
	var since := str(args.get("since", ""))
	var root: Node = ctx.tree.root if ctx.tree else null
	if root == null:
		return {"error": {"code": -32601, "message": "Editor SceneTree root unavailable",
			"reason": "editor_unavailable",
			"suggested": ["is the editor running?"]}}
	var found: Node = _find_with_method(root, "get_deltas")
	if found == null:
		return {"error": {"code": -32601, "message": "HumanEdit plugin not loaded",
			"reason": "plugin_not_loaded",
			"suggested": ["enable the HumanEdit editor plugin in Project Settings",
				"restart the editor"]}}
	return {"deltas": found.get_deltas(since)}


## Depth-first search for the first node that has the given method.
func _find_with_method(node: Node, method: String) -> Node:
	if node.has_method(method):
		return node
	for c in node.get_children():
		var r := _find_with_method(c, method)
		if r != null:
			return r
	return null
