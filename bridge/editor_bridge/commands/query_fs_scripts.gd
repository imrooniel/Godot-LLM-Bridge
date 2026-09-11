@tool
extends RefCounted

## query.fs.scripts — script files in one directory.
## Args: {"path": "res://"} (empty = res://)

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
		elif name.ends_with(".gd") or name.ends_with(".cs") or name.ends_with(".lua"):
			files.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	return {"ok": true, "path": path, "files": files, "directories": directories}
