@tool
extends RefCounted

## query.state — full editor state (the single source of truth).
## Same shape as .tmp/bridge/state.json, but computed synchronously.

func execute(_args: Dictionary, ctx) -> Dictionary:
	var result: Dictionary = {"ok": true}
	result.merge(ctx.state)
	# Live scan flag (the async scan is triggered by action.fs.scan; the CLI
	# polls this until false). Not part of the core state snapshot because a
	# scan finishes within seconds.
	var ei = ctx.editor_interface
	if ei != null:
		result["fs_scanning"] = ei.get_resource_filesystem().is_scanning()
	return result
