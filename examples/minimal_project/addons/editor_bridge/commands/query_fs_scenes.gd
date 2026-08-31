@tool
extends RefCounted

## query.fs.scenes — all .tscn scenes in the project (recursive).
## Each level opens its OWN DirAccess (the list_dir_begin/get_next API is a
## single non-reentrant iterator, so a shared handle would break recursion).

func execute(_args: Dictionary, _ctx) -> Dictionary:
	var scenes: Array = []
	_scan("res://", scenes)
	return {"ok": true, "scenes": scenes, "count": scenes.size()}


func _scan(dir_path: String, scenes: Array) -> void:
	# dir_path always ends with "/"
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		var full: String = dir_path + name
		if dir.current_is_dir():
			if name != ".godot" and not name.begins_with("."):
				_scan(dir_path + name + "/", scenes)
		elif name.ends_with(".tscn"):
			scenes.append({"path": full, "name": name.get_basename()})
		name = dir.get_next()
	dir.list_dir_end()
