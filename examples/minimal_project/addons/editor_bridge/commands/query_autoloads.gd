@tool
extends RefCounted

## query.autoloads — project autoloads (name + script path).

func execute(_args: Dictionary, ctx) -> Dictionary:
	var autoloads: Array[Dictionary] = []
	for setting: Dictionary in ProjectSettings.get_property_list():
		var name: String = str(setting.get("name", ""))
		if name.begins_with("autoload/"):
			var kv: PackedStringArray = name.split("/", false)
			if kv.size() >= 3:
				var aname: String = kv[1]
				var apath: String = str(ProjectSettings.get_setting(name))
				autoloads.append({"name": aname, "path": apath})
	return {"ok": true, "autoloads": autoloads}
