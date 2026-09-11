@tool
extends RefCounted

## action.editor.dialog.accept — accept (OK) a visible editor dialog whose
## OK button text matches. Primarily used to dismiss the "Files have been
## modified outside Godot" popup (OK button "Reload from disk") after editing
## a file on disk that the editor has open.
##
## Emits "pressed" on the matched OK button, which runs AcceptDialog's normal
## _ok_pressed() flow: hide the dialog + emit "confirmed" (the editor's
## reload callbacks fire).
##
## Args: {"ok_button": "Reload from disk"}

func execute(args: Dictionary, ctx) -> Dictionary:
	var match_text: String = str(args.get("ok_button", ""))
	if match_text.is_empty():
		return ctx.make_error(-32602, "ok_button (button text to match) required")
	var btn = _find_ok_button(ctx.tree.root, match_text, 0)
	if btn == null:
		return ctx.make_error(-32602, "No visible dialog with OK button '%s'" % match_text)
	btn.emit_signal("pressed")
	return {"ok": true, "accepted": match_text}


func _find_ok_button(node, match_text: String, depth: int):
	if node == null or depth > 45:
		return null
	if node is AcceptDialog and node.visible:
		var okb = node.get_ok_button()
		if okb != null and okb.text == match_text:
			return okb
	for child in node.get_children():
		var r = _find_ok_button(child, match_text, depth + 1)
		if r != null:
			return r
	return null
