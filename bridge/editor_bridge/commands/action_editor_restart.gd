@tool
extends RefCounted

## action.editor.restart — restart the editor (saves open scenes first).
## The response is written before the restart takes effect.

func execute(_args: Dictionary, ctx) -> Dictionary:
	ctx.editor_interface.restart_editor(true)
	return {"ok": true, "note": "Editor restarting — re-run 'launch' or wait and 'ping'"}
