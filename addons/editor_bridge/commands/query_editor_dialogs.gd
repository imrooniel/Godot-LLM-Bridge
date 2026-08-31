@tool
extends RefCounted

## query.editor.dialogs — list visible editor dialogs.
## Detects the "Files have been modified outside Godot" popup (a
## ConfirmationDialog whose OK button is "Reload from disk") that appears when
## an open scene or project.godot is modified on disk outside the editor.
##
## Returns: {"ok": true, "count": N, "dialogs": [{type, title, text,
##          ok_button, cancel_button, path}, ...]}

func execute(_args: Dictionary, ctx) -> Dictionary:
	var dialogs: Array = []
	_collect(ctx.tree.root, dialogs, 0)
	return {"ok": true, "dialogs": dialogs, "count": dialogs.size()}


func _collect(node, out: Array, depth: int) -> void:
	if node == null or depth > 45:
		return
	# Note: node stays UNtyped (no `var d: AcceptDialog = node` — that typed
	# assignment from an untyped value triggers a 4.6.1 "Opcode 28" VM bug).
	# The editor root is an EditorNode (not an AcceptDialog), so no root check.
	if node is AcceptDialog and node.visible:
		var info: Dictionary = {
			"type": node.get_class(),
			"title": node.get_title(),  # Window.get_title() — NOT get_window_title() (Godot 3 name)
			"text": node.get_text(),
			"path": node.get_path(),
		}
		var okb = node.get_ok_button()
		info["ok_button"] = okb.text if okb != null else ""
		if node is ConfirmationDialog:
			var cb = node.get_cancel_button()
			info["cancel_button"] = cb.text if cb != null else ""
		out.append(info)
	for child in node.get_children():
		_collect(child, out, depth + 1)
