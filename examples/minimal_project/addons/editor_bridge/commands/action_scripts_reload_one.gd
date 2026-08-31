@tool
extends RefCounted

## action.scripts.reload_one — reload a single script (instances keep state).
## Args: {"path": "res://scripts/foo.gd"}
## On parse errors the previously working code is kept and the error is
## reported in the logs (GDScript.reload behavior, gdscript.cpp:831-856).

func execute(args: Dictionary, ctx) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return ctx.make_error(-32602, "Script path required")
	if not ResourceLoader.exists(path):
		return ctx.make_error(-32602, "Script not found: " + path)

	var canonical: GDScript = load(path)
	if canonical == null:
		return ctx.make_error(-32603, "Script failed to load (parse error? check logs): " + path)
	var fresh: GDScript = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if fresh == null or not fresh.can_instantiate():
		return ctx.make_error(-32603, "Script failed to compile (check logs): " + path)

	canonical.set_source_code(fresh.get_source_code())
	var err: Error = canonical.reload(true)
	if err != Error.OK:
		return ctx.make_error(-32603, "Script reload failed (error %d, check logs): %s" % [err, path])

	ctx.emit_event.call("script_reloaded", {"path": path})
	return {"ok": true, "path": path}
