@tool
extends RefCounted

## query.state — full editor state (the single source of truth).
## Same shape as .tmp/bridge/state.json, but computed synchronously.

func execute(_args: Dictionary, ctx) -> Dictionary:
	var result: Dictionary = {"ok": true}
	result.merge(ctx.state)
	return result
