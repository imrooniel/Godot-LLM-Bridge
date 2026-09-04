@tool
extends EditorPlugin

## Editor Bridge — file-mailbox bridge between CLI tools and the Godot editor.
##
## Transport (no sockets in the editor — no half-open connections,
## crash-proof, parallel by construction):
##   .tmp/bridge/inbox/<id>.json      CLI -> editor requests (atomic rename)
##   .tmp/bridge/outbox/<id>.json     editor -> CLI responses
##   .tmp/bridge/events/<client>.jsonl  streaming events for subscribers
##   .tmp/bridge/state.json           heartbeat + full state (every 250 ms)
##
## Command routing:
##   ping / subscribe / unsubscribe  core builtins (this file)
##   game.<method>                   proxied over TCP to the in-game
##                                   DebugBridge (127.0.0.1:5555)
##   anything else                   loaded from commands/<name>.gd at call
##                                   time with CACHE_MODE_IGNORE — edits on
##                                   disk apply to the NEXT call, no editor
##                                   restart needed (only changes to THIS
##                                   core file require a restart)
##
## Events emitted (to subscribed clients):
##   log, console, scene_opened, scene_closed, scene_saved,
##   game_started, game_stopped, state,
##   debugger_dap, debugger_stopped, debugger_continued, debugger_output,
##   debugger_terminated, debugger_exited, debugger_breakpoint,
##   debugger_custom, script_reloaded, scripts_reloaded
##
## Only active in editor mode. Zero overhead in exports.

const VERSION := "2.2.0"

# Helper modules (preloaded — the addon does not register global class_names).
const BridgeContextScript := preload("res://addons/editor_bridge/bridge_context.gd")
const DapSessionScript := preload("res://addons/editor_bridge/dap_session.gd")
const GameProxyScript := preload("res://addons/editor_bridge/game_proxy.gd")
const LogCollectorScript := preload("res://addons/editor_bridge/log_collector.gd")

const BRIDGE_DIR := "res://.tmp/bridge"
const INBOX_DIR := BRIDGE_DIR + "/inbox"
const OUTBOX_DIR := BRIDGE_DIR + "/outbox"
const EVENTS_DIR := BRIDGE_DIR + "/events"
const STATE_PATH := BRIDGE_DIR + "/state.json"
const COMMANDS_DIR := "res://addons/editor_bridge/commands"

const POLL_INTERVAL_S := 0.05
const HEARTBEAT_INTERVAL_MS := 250
const PANEL_CHECK_TICKS := 10      # check the Output panel every ~500 ms
const PANEL_RETRY_TICKS := 40      # retry panel discovery every ~2 s
const CLEANUP_INTERVAL_MS := 5000
const ORPHAN_AGE_MS := 30000       # inbox/outbox files older than this: gone
const EVENT_FILE_MAX_AGE_MS := 600000

var _poll_timer: Timer = null
var _ctx: BridgeContextScript = null
var _log_collector: LogCollectorScript = null
var _game_proxy: GameProxyScript = null
## Persistent DAP client (Godot 4.8 built-in debug adapter, default :6006).
var _dap: DapSessionScript = null

var _subscribers: Dictionary = {}  # client_id -> {"events": Array[String], "state": bool}
var _prev_snapshot: Dictionary = {}
var _last_heartbeat_ms := 0
var _last_cleanup_ms := 0
var _state_dirty := true
var _tick := 0

# Output panel (EditorLog node, name "Output") — lazy discovery.
var _output_panel: Node = null
var _output_panel_text: Node = null
var _last_panel_text := ""

# Cached editor constants (stable for the process lifetime).
var _project_name := ""
var _project_path := ""
var _godot_version := ""


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _enter_tree() -> void:
	_make_dirs()

	_project_name = str(ProjectSettings.get_setting("application/config/name"))
	_project_path = ProjectSettings.globalize_path("res://").trim_suffix("/")
	_godot_version = Engine.get_version_info().string

	_log_collector = LogCollectorScript.new()
	OS.add_logger(_log_collector)
	_game_proxy = GameProxyScript.new()

	_ctx = BridgeContextScript.new()
	_ctx.editor_interface = get_editor_interface()
	_ctx.tree = get_tree()
	_ctx.log_collector = _log_collector
	_ctx.game_proxy = _game_proxy
	_ctx.emit_event = _emit_event
	_ctx.respond = func(i: String, r: Dictionary) -> void: _write_response(i, r)

	# DAP: the editor's built-in debug adapter server (4.8+). Enable
	# sync_breakpoints so our initialize re-announces existing breakpoints
	# instead of clearing them (a fresh DAP client clears them by default).
	var dap_port: int = 6006
	var ei: EditorInterface = get_editor_interface()
	var es: EditorSettings = ei.get_editor_settings() if ei else null
	if es:
		var sb: Variant = es.get_setting("network/debug_adapter/sync_breakpoints")
		if sb != true:
			es.set_setting("network/debug_adapter/sync_breakpoints", true)
		var dp: Variant = es.get_setting("network/debug_adapter/remote_port")
		dap_port = int(dp) if dp != null else 6006
	_dap = DapSessionScript.new()
	_dap.setup(self, dap_port)
	_dap.state_changed.connect(_on_dap_state_changed)
	_ctx.dap = _dap

	_find_output_panel()
	get_tree().node_added.connect(_on_root_node_added)  # SceneTree signal (root is a Window)

	_update_state()
	_write_heartbeat()
	_prev_snapshot = _current_snapshot()
	_last_heartbeat_ms = Time.get_ticks_msec()
	_last_cleanup_ms = _last_heartbeat_ms

	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL_S
	_poll_timer.timeout.connect(_poll)
	add_child(_poll_timer)
	_poll_timer.start()

	print("[EditorBridge] Mailbox bridge ready (v%s) — %s" % [VERSION, BRIDGE_DIR])


func _exit_tree() -> void:
	if _poll_timer:
		_poll_timer.stop()
		_poll_timer.queue_free()
	_poll_timer = null
	if _log_collector:
		OS.remove_logger(_log_collector)
		_log_collector = null
	if _game_proxy:
		_game_proxy.reset()
		_game_proxy = null
	if _dap:
		_dap.free()
		_dap = null
	var tree := get_tree()
	if tree and tree.node_added.is_connected(_on_root_node_added):
		tree.node_added.disconnect(_on_root_node_added)
	# Clean shutdown signal for the CLI (fresh-heartbeat check fails fast).
	DirAccess.remove_absolute(STATE_PATH)


# ---------------------------------------------------------------------------
# Poll loop (20 Hz)
# ---------------------------------------------------------------------------

func _poll() -> void:
	_tick += 1
	_ctx.editor_interface = get_editor_interface()  # fresh each tick (singleton)
	_dap.tick()
	_update_state()
	_drain_inbox()
	for done: Dictionary in _game_proxy.tick():
		_write_game_completion(done)
	_diff_state()
	_drain_logs()
	if _tick % PANEL_CHECK_TICKS == 0:
		_drain_panel()
	if _output_panel == null and _tick % PANEL_RETRY_TICKS == 0:
		_find_output_panel()
	var now := Time.get_ticks_msec()
	if _state_dirty or now - _last_heartbeat_ms >= HEARTBEAT_INTERVAL_MS:
		_write_heartbeat()
		_last_heartbeat_ms = now
		_state_dirty = false
	if now - _last_cleanup_ms >= CLEANUP_INTERVAL_MS:
		_cleanup()
		_last_cleanup_ms = now


# ---------------------------------------------------------------------------
# Inbox: request execution
# ---------------------------------------------------------------------------

func _drain_inbox() -> void:
	var files: Array[String] = _list_files(INBOX_DIR, ".json")
	files.sort()
	for file_name: String in files:
		_process_request_file(INBOX_DIR + "/" + file_name)


func _process_request_file(path: String) -> void:
	var id: String = path.get_file().trim_suffix(".json")
	var data: Variant = JSON.parse_string(_read_file(path))
	DirAccess.remove_absolute(path)  # always consume, even on parse errors
	if not (data is Dictionary):
		_write_response(id, _error(-32700, "Invalid request JSON"))
		return
	var cmd: String = str(data.get("cmd", ""))
	var args: Variant = data.get("args", {})
	var timeout: float = float(data.get("timeout", 10.0))
	if not (args is Dictionary):
		args = {}
	# Variant: a Dictionary response, or null = async (game proxy)
	var response: Variant = _execute(id, cmd, args, timeout)
	if response != null:
		_write_response(id, response)
	# null = async game proxy — outbox is written when tick() completes it


func _execute(id: String, cmd: String, args: Dictionary, timeout: float) -> Variant:
	if cmd == "ping":
		return {"ok": true, "pong": true, "version": VERSION, "subscribers": _subscribers.size()}
	if cmd == "subscribe":
		return _subscribe(args)
	if cmd == "unsubscribe":
		return _unsubscribe(args)
	if cmd.begins_with("game."):
		return _proxy_game(id, cmd, args, timeout)
	return _run_command(id, cmd, args)


## Load a command script from disk and execute it.
##
## CACHE_MODE_IGNORE always re-reads and recompiles from disk (verified:
## IGNORE loads are not registered in the ResourceCache — the resource is
## fresh, and freed when we drop the reference). So a command edited on
## disk takes effect on the very next call — no editor restart.
func _run_command(id: String, cmd: String, args: Dictionary) -> Variant:
	var path: String = "%s/%s.gd" % [COMMANDS_DIR, cmd.replace(".", "_")]
	if not ResourceLoader.exists(path):
		return _error(-32601, "Unknown command: %s (no %s)" % [cmd, path])
	var script: GDScript = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if script == null or not script.can_instantiate():
		return _error(-32603, "Command script failed to load or compile: %s (check logs)" % cmd)
	var handler: RefCounted = script.new()
	_ctx.current_request_id = id  # for async responses (e.g. DAP requests)
	var result: Variant = handler.execute(args, _ctx)
	handler = null  # drop instance so the script can be reloaded next time
	if result == null:
		return null  # async: the response is written later (e.g. DAP request)
	if not (result is Dictionary):
		return _error(-32603, "Command '%s' returned an invalid response" % cmd)
	if not result.has("ok"):
		result["ok"] = not (result as Dictionary).has("error")
	return result


# ---------------------------------------------------------------------------
# Game proxy (editor -> game process, port 5555)
# ---------------------------------------------------------------------------

func _proxy_game(id: String, cmd: String, args: Dictionary, timeout: float) -> Variant:
	var method: String = cmd.substr(5)
	if not _game_proxy.start_request(id, method, args, timeout):
		var playing: bool = bool(_ctx.state.get("game", {}).get("running", false))
		var note: String
		if playing:
			note = "Is the game bridge still starting?"
		else:
			note = "Is the game running with the DebugBridge autoload?"
		return _error(-32001,
			"Game bridge unreachable at %s:%d (editor says game running: %s). %s"
			% [GameProxyScript.HOST, GameProxyScript.PORT, str(playing), note])
	return null  # response arrives via _game_proxy.tick()


func _write_game_completion(done: Dictionary) -> void:
	var id: String = str(done.get("id", ""))
	if done.has("response"):
		var resp: Dictionary = done.response
		if resp.has("error"):
			_write_response(id, _error(int(resp.error.get("code", -32000)), str(resp.error.get("message", "game error"))))
		else:
			var out: Dictionary = {"ok": true}
			var result: Variant = resp.get("result", resp)
			if result is Dictionary:
				out.merge(result)
			else:
				out["value"] = result
			_write_response(id, out)
	else:
		_write_response(id, _error(-32001, str(done.get("error", "game bridge error"))))


# ---------------------------------------------------------------------------
# Subscribe / events
# ---------------------------------------------------------------------------

func _subscribe(args: Dictionary) -> Dictionary:
	var client_id: String = str(args.get("client_id", ""))
	if client_id.is_empty() or not client_id.is_valid_filename():
		return _error(-32602, "client_id required (any valid filename)")
	var events: Array[String] = []
	for e: Variant in args.get("events", []):
		if e is String:
			events.append(e)
	var state_sub: bool = bool(args.get("state", false))
	if events.is_empty() and not state_sub:
		return _error(-32602, "Provide 'events' (list of event names) or 'state': true")
	_subscribers[client_id] = {"events": events, "state": state_sub}
	return {"ok": true, "client_id": client_id, "events": events, "state": state_sub}


func _unsubscribe(args: Dictionary) -> Dictionary:
	var client_id: String = str(args.get("client_id", ""))
	if _subscribers.erase(client_id):
		DirAccess.remove_absolute("%s/%s.jsonl" % [EVENTS_DIR, client_id])
	return {"ok": true}


func _emit_event(event: String, data: Dictionary) -> void:
	if _subscribers.is_empty():
		return
	var payload: Dictionary = {"ts": Time.get_unix_time_from_system(), "event": event, "data": data}
	var line: String = JSON.stringify(payload, "", false)
	for client_id: String in _subscribers.keys():
		var sub: Dictionary = _subscribers[client_id]
		var is_state: bool = bool(sub.get("state", false))
		var wanted: Array = sub.get("events", [])
		var matches: bool = (event == "state" and is_state) or (event != "state" and wanted.has(event))
		if matches:
			_append_event_line(client_id, line)


func _append_event_line(client_id: String, line: String) -> void:
	var path: String = "%s/%s.jsonl" % [EVENTS_DIR, client_id]
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end(0)
	f.store_string(line + "\n")
	f.close()


func _drain_logs() -> void:
	var lines: Array[String] = _log_collector.flush_pending()
	if not lines.is_empty():
		for line: String in lines:
			_emit_event("log", {"line": line})


# ---------------------------------------------------------------------------
# State + heartbeat
# ---------------------------------------------------------------------------

func _update_state() -> void:
	var ei := get_editor_interface()
	var current_root: Node = ei.get_edited_scene_root() if ei else null
	var playing: bool = ei.is_playing_scene() if ei else false
	_ctx.state = {
		"editor": {
			"pid": OS.get_process_id(),
			"project_name": _project_name,
			"project_path": _project_path,
			"godot_version": _godot_version,
			"plugin_version": VERSION,
		},
		"scenes": {
			"open": Array(ei.get_open_scenes()) if ei else [],
			"current": current_root.scene_file_path if current_root else "",
			"current_scene_name": current_root.name if current_root else "",
			"unsaved": _unsaved_scenes(ei),
		},
		"game": {
			"running": playing,
			"playing_scene": ei.get_playing_scene() if ei else "",
			"bridge_port": GameProxyScript.PORT if playing else 0,
			"bridge_connected": _game_proxy.is_reachable() if _game_proxy else false,
		},
		"debugger": _dap.get_state() if _dap else {"connected": false},
		"subscribers": _subscribers.size(),
	}


func _current_snapshot() -> Dictionary:
	var ei := get_editor_interface()
	if ei == null:
		return {}
	return {
		"open": Array(ei.get_open_scenes()),
		"unsaved": _unsaved_scenes(ei),
		"playing": ei.is_playing_scene(),
		"playing_scene": ei.get_playing_scene(),
	}


## get_unsaved_scenes() only exists in Godot 4.7+; the installed binary is
## 4.6.1, so guard with has_method (cast to Variant to defer resolution).
func _unsaved_scenes(ei: EditorInterface) -> Array:
	if ei == null:
		return []
	var e: Variant = ei
	if e.has_method("get_unsaved_scenes"):
		return Array(e.get_unsaved_scenes())
	return []


## The state diff is the single source of scene/game events — it catches
## BOTH CLI-initiated actions and human actions in the editor UI.
func _diff_state() -> void:
	var cur := _current_snapshot()
	if cur.is_empty():
		return
	if _prev_snapshot.is_empty():
		_prev_snapshot = cur
		return
	var changed := false
	for p: String in cur.open:
		if not _prev_snapshot.open.has(p):
			_emit_event("scene_opened", {"path": p})
			changed = true
	for p: String in _prev_snapshot.open:
		if not cur.open.has(p):
			_emit_event("scene_closed", {"path": p})
			changed = true
	for p: String in _prev_snapshot.unsaved:
		if not cur.unsaved.has(p):
			_emit_event("scene_saved", {"path": p})
			changed = true
	if cur.playing and not _prev_snapshot.playing:
		_emit_event("game_started", {"scene": cur.playing_scene})
		if _dap:
			_dap.on_game_started()
		changed = true
	elif not cur.playing and _prev_snapshot.playing:
		_emit_event("game_stopped", {})
		if _dap:
			_dap.on_game_stopped()
		changed = true
	_prev_snapshot = cur
	if changed:
		_state_dirty = true
		_emit_event("state", _ctx.state)


func _write_heartbeat() -> void:
	var payload: Dictionary = _ctx.state.duplicate(true)
	payload["alive"] = true
	payload["heartbeat_ms"] = int(Time.get_unix_time_from_system() * 1000.0)
	_atomic_write(STATE_PATH, JSON.stringify(payload, "", false))


# ---------------------------------------------------------------------------
# Output panel (editor log: editor output + game output)
# ---------------------------------------------------------------------------

func _on_root_node_added(node: Node) -> void:
	if _output_panel == null and (node.get_class() == "EditorLog" or node.name == "Output"):
		_find_output_panel()


func _find_output_panel() -> void:
	if _output_panel != null:
		return
	var found := _search_for_output(get_tree().root)
	if found == null:
		return
	_output_panel = found
	_output_panel_text = _find_text_node(found)
	_last_panel_text = _panel_text()
	_ctx.output_panel_text = _output_panel_text
	print("[EditorBridge] Output panel found (%s)" % found.get_class())


func _search_for_output(node: Node, depth: int = 0) -> Node:
	if node == null or depth > 40:
		return null
	if node.get_class() == "EditorLog" or node.name == "Output":
		return node
	for child in node.get_children():
		var result := _search_for_output(child, depth + 1)
		if result != null:
			return result
	return null


func _find_text_node(panel: Node) -> Node:
	for child in panel.get_children():
		if child is RichTextLabel or child is TextEdit:
			return child
		var deeper := _find_text_node(child)
		if deeper != null:
			return deeper
	return null


func _panel_text() -> String:
	if _output_panel_text == null or not (_output_panel_text is RichTextLabel):
		return ""
	# 4.8: on the threaded EditorLog label, get_text()/the `text` property
	# return "" — get_parsed_text() is the one that returns the full visible
	# log (BBCode stripped). Verified live via query.editor.log.probe.
	return _output_panel_text.get_parsed_text()


## Poll-based (no signal dependency): extract new lines from the panel's
## rolling text window. The common case is a pure append; when the window
## rolls, find the suffix of the old text that still prefixes the new.
func _drain_panel() -> void:
	var text := _panel_text()
	if text == _last_panel_text:
		return
	var fresh: Array
	if _last_panel_text.is_empty():
		fresh = []  # first read = baseline, nothing to emit
	elif text.begins_with(_last_panel_text):
		fresh = text.substr(_last_panel_text.length()).split("\n")
	else:
		var max_skip: int = mini(_last_panel_text.length(), text.length())
		var i := 0
		while i < max_skip and text[i] != _last_panel_text[i]:
			i += 1
		fresh = text.substr(_last_panel_text.length() - i).split("\n")
	_last_panel_text = text
	var non_empty: Array = []
	for line: String in fresh:
		if not line.is_empty():
			non_empty.append(line)
	if not non_empty.is_empty():
		_emit_event("console", {"lines": non_empty})


# ---------------------------------------------------------------------------
# File utilities
# ---------------------------------------------------------------------------

func _make_dirs() -> void:
	for d: String in [BRIDGE_DIR, INBOX_DIR, OUTBOX_DIR, EVENTS_DIR]:
		if not DirAccess.dir_exists_absolute(d):
			DirAccess.make_dir_recursive_absolute(d)


func _list_files(dir_path: String, suffix: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(suffix):
			out.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	return out


func _read_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## Write to a temp file + atomic rename — readers never see partial files.
func _atomic_write(path: String, text: String) -> void:
	var tmp: String = path + ".tmp-%d" % OS.get_process_id()
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("[EditorBridge] Cannot write %s" % tmp)
		return
	f.store_string(text)
	f.close()
	DirAccess.rename_absolute(tmp, path)


func _write_response(id: String, response: Dictionary) -> void:
	if not response.has("id"):
		response["id"] = id
	_atomic_write("%s/%s.json" % [OUTBOX_DIR, id], JSON.stringify(response, "", false))


func _error(code: int, message: String) -> Dictionary:
	return {"ok": false, "error": {"code": code, "message": message}}


## Delete files left behind by crashed clients/editor sessions.
func _cleanup() -> void:
	var now := Time.get_ticks_msec()
	_purge_old_files(INBOX_DIR, ORPHAN_AGE_MS, now)
	_purge_old_files(OUTBOX_DIR, ORPHAN_AGE_MS, now)
	for file_name: String in _list_files(EVENTS_DIR, ".jsonl"):
		var path: String = EVENTS_DIR + "/" + file_name
		var client_id: String = file_name.trim_suffix(".jsonl")
		if not _subscribers.has(client_id) and now - _file_mtime_ms(path) > EVENT_FILE_MAX_AGE_MS:
			DirAccess.remove_absolute(path)


func _purge_old_files(dir_path: String, max_age_ms: int, now: int) -> void:
	for file_name: String in _list_files(dir_path, ".json"):
		var path: String = dir_path + "/" + file_name
		if now - _file_mtime_ms(path) > max_age_ms:
			DirAccess.remove_absolute(path)


func _file_mtime_ms(path: String) -> int:
	return int(FileAccess.get_modified_time(path) * 1000.0)


# ---------------------------------------------------------------------------
# DAP (Debug Adapter Protocol) session state
# ---------------------------------------------------------------------------

## DAP connection/session state changed — refresh the state snapshot so the
## heartbeat + `query state` reflect it immediately.
func _on_dap_state_changed() -> void:
	_update_state()
	_state_dirty = true
