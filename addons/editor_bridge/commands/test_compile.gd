@tool
extends RefCounted

## test.compile — compile-check scripts via the live editor (forces a fresh
## load, so parse errors in a just-edited script are caught without a restart).
## Args: {"paths": ["res://..."]}  ->  {path: "OK" | "LOAD FAILED" | "CANNOT INSTANTIATE ..."}

func execute(args: Dictionary, _ctx) -> Dictionary:
	var paths: Array = args.get("paths", [])
	var out: Dictionary = {}
	for p: Variant in paths:
		var s: GDScript = ResourceLoader.load(str(p), "", ResourceLoader.CACHE_MODE_IGNORE)
		if s == null:
			out[str(p)] = "LOAD FAILED"
		elif not s.can_instantiate():
			out[str(p)] = "CANNOT INSTANTIATE (parse error — check editor logs)"
		else:
			out[str(p)] = "OK"
	return out
