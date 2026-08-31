@tool
extends RefCounted

## action.scripts.reload — reload every .gd script in the project.
## Uses the engine's own hot-reload pattern (gdscript.cpp:2555-2566):
## fresh CACHE_MODE_IGNORE load, copy source into the canonical cached
## resource, then reload(true) — instances keep their state.

func execute(_args: Dictionary, ctx) -> Dictionary:
	var reloaded := 0
	var failed: Array[String] = []
	for path: String in _list_gd_files("res://"):
		var canonical: GDScript = load(path)
		if canonical == null:
			continue
		var fresh: GDScript = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if fresh == null or not fresh.can_instantiate():
			failed.append(path)
			continue
		canonical.set_source_code(fresh.get_source_code())
		if canonical.reload(true) == Error.OK:
			reloaded += 1
		else:
			failed.append(path)
	ctx.emit_event.call("scripts_reloaded", {"reloaded": reloaded, "failed": failed})
	return {"ok": true, "reloaded": reloaded, "failed": failed}


func _list_gd_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			if name != ".godot" and not name.begins_with("."):
				out.append_array(_list_gd_files(dir_path + "/" + name))
		elif name.ends_with(".gd"):
			out.append(dir_path + "/" + name)
		name = dir.get_next()
	dir.list_dir_end()
	return out
