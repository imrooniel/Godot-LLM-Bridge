@tool
extends RefCounted

## Dependency container injected into command scripts.
##
## Commands are stateless RefCounted scripts loaded at call time;
## everything they need comes from here (explicit dependencies, no globals).
## The core owns all the resources and builds a fresh context view on
## every poll tick.

var editor_interface: EditorInterface = null
var tree: SceneTree = null

## Live state (same shape as state.json), refreshed by the core each tick.
var state: Dictionary = {}

## Mailbox id of the request currently being executed (async responses).
var current_request_id: String = ""

## Editor-process Logger collector (LogCollector).
var log_collector = null

## The editor Output panel's text node (RichTextLabel), null until found.
var output_panel_text: Node = null

## TCP proxy to the in-game DebugBridge (GameProxy, port 5555).
var game_proxy = null

## Persistent DAP client (Godot 4.8 built-in debug adapter, default :6006).
## API: get_state(), attach(id), launch(id, scene, args, no_debug), detach(id),
## set_breakpoints(id, file, lines), enqueue(id, command, args),
## breakpoints (dict), output_lines (ring), get_breakpoints().
## Note: enqueue()/attach()/launch() are ASYNC — the mailbox response is
## written when the DAP response arrives; command scripts return null.
var dap = null

## func(event: String, data: Dictionary) — emit a bridge event.
var emit_event: Callable = func(_e: String, _d: Dictionary) -> void: pass

## func(id: String, response: Dictionary) — write an async mailbox response.
## Command scripts that return null from execute() respond later via this
## (e.g. the DAP wire probe, which needs main-loop ticks to exchange data).
var respond: Callable = func(_i: String, _r: Dictionary) -> void: pass


func make_error(code: int, message: String, reason: String = "",
		suggested: Array = []) -> Dictionary:
	var e := {"ok": false, "error": {"code": code, "message": message}}
	if reason != "":
		e["error"]["reason"] = reason
	if not suggested.is_empty():
		e["error"]["suggested"] = suggested
	return e


## Returns the DAP client, or an error Dictionary if not initialized.
func require_dap() -> Variant:
	if dap == null:
		return make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	return dap


## Returns the DAP client, or an error Dictionary if not initialized OR not attached.
func require_dap_attached() -> Variant:
	var dap_or_err: Variant = require_dap()
	if dap_or_err is Dictionary:
		return dap_or_err
	var dap = dap_or_err
	if not dap.attached:
		return make_error(-32002, "Not attached (run `debugger attach` first)")
	return dap


func get_editor() -> Dictionary:
	return state.get("editor", {})


func get_scenes() -> Dictionary:
	return state.get("scenes", {})


func get_game() -> Dictionary:
	return state.get("game", {})
