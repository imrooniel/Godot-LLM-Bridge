@tool
extends RefCounted

## logs.clear — clear the editor-process collector buffer.
## (Output panel content is managed by the editor itself; use the panel's
## own clear. The process console log is append-only by design.)

func execute(_args: Dictionary, ctx) -> Dictionary:
	ctx.log_collector.clear_messages()
	return {"ok": true, "note": "cleared editor-process collector"}
