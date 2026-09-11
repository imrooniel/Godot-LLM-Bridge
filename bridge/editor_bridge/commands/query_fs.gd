@tool
extends RefCounted

## query.fs — list one directory of the project.
## Args: {"path": "res://"} (empty = res://)
## Note: uses DirAccess (not EditorFileSystem, which has no dir-iteration API
## in Godot 4.6). get_next() skips "." and ".." automatically.

func execute(args: Dictionary, ctx) -> Dictionary:
	var path: String = str(args.get("path", "res://"))
	if path.is_empty():
		path = "res://"
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return ctx.make_error(-32602, "Cannot open directory: " + path)
	var files: Array = []
	var directories: Array = []
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if dir.current_is_dir():
			directories.append(name)
		else:
			files.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	return {"ok": true, "path": path, "files": files, "directories": directories}
