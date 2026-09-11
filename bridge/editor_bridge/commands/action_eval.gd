@tool
extends RefCounted

## action.eval — evaluate ONE GDScript expression in the EDITOR process.
##
## Parity with `game gd-eval` for editor-side questions (project state,
## EditorInterface reachability, ClassDB in the editor build). Same hard
## rules via eval_policy: single expression, length cap, blacklist — plus
## editor-context prohibitions (quit_editor, save_quit, quit_play…).
##
## Compiles `return (expr)` as a fresh GDScript and calls it immediately.
## No autoloads exist here; use EditorInterface via ctx only through the
## dedicated commands (eval has no ctx access by design). Runtime errors
## print to the editor Output panel; the value comes back null.

const EvalPolicy := preload("res://bridge/editor_bridge/eval_policy.gd")


func execute(args: Dictionary, _ctx) -> Dictionary:
	var expr := str(args.get("expression", ""))
	var policy: String = EvalPolicy.validate(expr, true)
	if policy != "":
		return {"ok": false,
				"error": {"code": -32602, "message": "editor eval: " + policy}}
	var script := GDScript.new()
	script.source_code = "extends RefCounted\nfunc _ev() -> Variant:\n\treturn (%s)\n" % expr
	if script.reload() != OK:
		return {"ok": false, "error": {"code": -32602,
				"message": "editor eval: expression does not compile — exact "
				+ "parser message in the editor Output panel (game-side "
				+ "`game gd-eval` returns it inline)"}}
	var inst: RefCounted = script.new()
	var value: Variant = inst.call("_ev")
	return {"ok": true, "value": _serialize(value), "type": type_string(typeof(value))}


## JSON-safe projection: basics pass through, everything else stringifies.
func _serialize(value: Variant) -> Variant:
	if typeof(value) in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING]:
		return value
	match typeof(value):
		TYPE_ARRAY:
			var out: Array = []
			for item: Variant in value:
				out.append(_serialize(item))
			return out
		TYPE_DICTIONARY:
			var od: Dictionary = {}
			for key: Variant in value.keys():
				od[str(key)] = _serialize(value[key])
			return od
		_:
			return str(value)
