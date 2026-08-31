@tool
extends RefCounted

## query.editor — editor process info (pid, project, versions).

func execute(_args: Dictionary, ctx) -> Dictionary:
	var result: Dictionary = {"ok": true}
	result.merge(ctx.get_editor())
	return result
