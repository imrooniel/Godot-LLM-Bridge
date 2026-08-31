@tool
extends RefCounted

## action.editor.close — quit the editor process.
## DANGEROUS: ends the human's editor session. The response is written
## before the quit takes effect (0.5 s delay).

func execute(_args: Dictionary, ctx) -> Dictionary:
	var timer = ctx.tree.create_timer(0.5)
	timer.timeout.connect(func() -> void: ctx.tree.quit())
	return {"ok": true, "note": "Editor will close in ~0.5s"}
