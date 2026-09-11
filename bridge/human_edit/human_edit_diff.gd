## Pure snapshot/diff/coalesce logic for human-edit content deltas (spec §5.2).
## No editor/node dependencies — unit-testable headless (see scripts/tools/human_edit_test.gd).
## The @tool plugin (human_edit.gd) feeds it node data; it returns legible delta ops.
extends RefCounted

## Whitelisted per-class VALUE props to diff (spec §5.2 / §11 open question 1).
## Position/rotation/scale/visible/z_index are the default; class-specific additions below.
const DEFAULT_PROPS := ["position", "rotation", "rotation_degrees", "scale", "visible", "z_index"]
const CLASS_PROPS := {
	"AnimatedSprite2D": ["animation"],
	"Sprite2D": ["flip_h", "flip_v"],
	# TileMapLayer cell data + CollisionShape2D shapes are diffed BY HASH (see hash_*).
}

func _props_for(cname: String) -> Array:
	var out: Array = DEFAULT_PROPS.duplicate()
	if CLASS_PROPS.has(cname):
		out.append_array(CLASS_PROPS[cname])
	return out

## Build a snapshot dict for one node from a flat {name, class, …props} map.
func snapshot_node(n: Dictionary) -> Dictionary:
	var out := {"class": n.get("class", "")}
	for p in _props_for(str(n.get("class", ""))):
		if n.has(p):
			out[p] = _value(n[p])
	# Tile/shape hashes (spec §5.2): present when the node carries those.
	if n.has("__cell_hash"):
		out["cells"] = n["__cell_hash"]
	if n.has("__shape_hash"):
		out["shape"] = n["__shape_hash"]
	return out

func _value(v) -> Variant:
	if v is Vector2:
		return [v.x, v.y]
	if v is Vector2i:
		return [v.x, v.y]
	if v is Vector3:
		return [v.x, v.y, v.z]
	if v is Array:
		return _hash_str(str(v))  # hash big arrays (e.g. cell lists)
	return v

func diff_node(path: String, old: Dictionary, new: Dictionary) -> Array:
	var ops: Array = []
	var keys: Array = []
	for k in old.keys(): keys.append(k)
	for k in new.keys():
		if not old.has(k): keys.append(k)
	for k in keys:
		if k == "class":
			continue
		var has_old: bool = old.has(k)
		var has_new: bool = new.has(k)
		if has_old and has_new:
			if old[k] != new[k]:
				ops.append({"op": "set", "path": path, "prop": k, "from": old[k], "to": new[k]})
		elif has_new and not has_old:
			ops.append({"op": "set", "path": path, "prop": k, "from": null, "to": new[k]})
		elif has_old and not has_new:
			ops.append({"op": "set", "path": path, "prop": k, "from": old[k], "to": null})
	return ops

## Coalesce a batch to a cap; report how many were dropped as `summary`.
## Returns {"ops": [≤cap], "summary": <dropped_count>} (Dictionary, not a bare Array).
func coalesce(ops: Array, cap: int) -> Dictionary:
	if ops.size() <= cap:
		return {"ops": ops, "summary": 0}
	return {"ops": ops.slice(0, cap), "summary": ops.size() - cap}

## Hash a cell list (Array of [x,y,source_id,atlas,alt]) to a stable short string.
func hash_cells(cells: Array) -> String:
	var s := ""
	for c in cells:
		s += str(c) + ";"
	return _hash_str(s)

func _hash_str(s: String) -> String:
	# FNV-1a 32-bit, hex. Deterministic, no engine Random needed.
	var h := 2166136261
	for i in s.length():
		h = (h ^ s.unicode_at(i)) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	return "%08x" % h
