class_name BridgeContract
extends RefCounted

# The legibility contract (spec section 6). Every response is either
# {ok, state, result} or {ok=false, state, error{code,message,reason,suggested}}.
# `state` is always present on the wire even when it would otherwise be empty,
# so the LLM has a single shape to parse. `reason` is the actionable signal
# ("what do I do now") and `suggested` is a short list of next calls.

static func ok(result, state: Dictionary = {}) -> Dictionary:
	var out := { "ok": true, "state": state, "result": result }
	return out

static func err(code: int, message: String, reason: String,
		suggested: Array = [], state: Dictionary = {}) -> Dictionary:
	return {
		"ok": false,
		"state": state,
		"error": { "code": code, "message": message, "reason": reason, "suggested": suggested },
	}

static func state_object(editor_running: bool, game_status: Dictionary,
		breaked: bool, turn: Dictionary = {}) -> Dictionary:
	return {
		"godot": "editor" if editor_running else ("game" if game_status.get("running", false) else "none"),
		"editor_running": editor_running,
		"game": game_status,
		"breaked": breaked,
		"turn": turn,
	}

# True when the game channel is unreachable (the CLI's connect-fail case),
# as opposed to a response that arrived and is itself an error.
static func is_transport_error(res: Variant) -> bool:
	return (res is Dictionary) and res.has("connect_error")
