extends Node
# DebugBridge — standalone TCP socket bridge for AI-driven UI interaction.
#
# Install: add to [autoload] in project.godot:
#   DebugBridge="*res://debug_bridge.gd"
#
# Only active in debug builds. Zero overhead in exports.

const _LogCollectorScript := preload("res://autoloads/debug_log_collector.gd")
const DEFAULT_PORT := 5555
const MAX_PORT_ATTEMPTS := 10
const REQUEST_TIMEOUT_SECS := 60.0
const MAX_BUFFER_BYTES := 1_048_576  # 1 MB

var _server: TCPServer
var _client: StreamPeerTCP
var _buffer: String = ""
var _bound_port: int = 0
var _client_connect_time_ms: int = 0
var _poll_timer: Timer
var _lua_vm: Node = null

func _ready() -> void:
	if not OS.is_debug_build():
		return

	# Ensure this autoload always runs even when scene is paused
	process_mode = Node.PROCESS_MODE_ALWAYS

	_server = TCPServer.new()
	_init_handlers()
	_init_log_collector()
	_clear_logs_for_session()
	_start_listening()

	# Use a Timer to poll the socket — works reliably even when scene is paused
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 0.016  # ~60fps
	_poll_timer.one_shot = false
	_poll_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_poll_timer.timeout.connect(_poll_socket)
	add_child(_poll_timer)
	_poll_timer.start()
	if _debug_verbose:
		print("[DBridge] Timer started, process_mode=%d" % _poll_timer.process_mode)

func _start_listening() -> void:
	for attempt in range(MAX_PORT_ATTEMPTS):
		var try_port: int = DEFAULT_PORT + attempt
		var err: Error = _server.listen(try_port, "127.0.0.1")
		if err == Error.OK:
			_bound_port = try_port
			if _debug_verbose:
				print("[DBridge] Listening on 127.0.0.1:%d" % try_port)
			return
	print("[DBridge] Failed to bind to any port %d-%d" % [DEFAULT_PORT, DEFAULT_PORT + MAX_PORT_ATTEMPTS - 1])
	set_process(false)

func _poll_socket() -> void:
	if _server == null:
		return

	# Check if current client has disconnected (detect before accepting new)
	if _client != null:
		_client.poll()
		var status: int = _client.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED and status != StreamPeerTCP.STATUS_CONNECTING:
			if _debug_verbose:
				print_rich("[color=cyan][DBridge] Client disconnected (status: %d)[/color]" % status)
			_close_client()

	# Accept new connection if none active
	if _client == null and _server.is_connection_available():
		_client = _server.take_connection()
		_client.set_no_delay(true)
		_buffer = ""
		_client_connect_time_ms = Time.get_ticks_msec()
		if _debug_verbose:
			print_rich("[color=cyan][DBridge] Client connected[/color]")

	# Process existing connection
	if _client != null:
		# Read only available bytes to avoid blocking
		var available: int = _client.get_available_bytes()
		if available > 0:
			var result: Array = _client.get_partial_data(available)
			var err: Error = result[0]
			var raw: PackedByteArray = result[1]
			var byte_count: int = raw.size()

			if byte_count > 0:
				var text: String = raw.get_string_from_utf8()
				_buffer += text
				_client_connect_time_ms = Time.get_ticks_msec()
				if _debug_verbose:
					print_rich("[color=green][DBridge] Read %d bytes -> %d chars (err=%d, buf: %d)[/color]" % [
						byte_count, text.length(), err, _buffer.length()
					])
				_process_commands()

		# NOTE: execute_lua now runs INLINE on the main thread (in
		# _cmd_execute_lua), so there is no background thread to poll and no
		# deferred result to deliver here. The old async thread-polling block
		# (the "wedge fix") is retired — it made Lua-driven Godot calls fail
		# ("caller thread can't call ... on this node"), breaking the
		# presentation layer. See _cmd_execute_lua for the rationale.

		# Flush pending log notifications (from thread-safe Logger queue)
		if _log_collector != null:
			var pending: Array[String] = _log_collector.flush_pending()
			for notif_text in pending:
				_send_log_notification(notif_text)

		var idle_ms := Time.get_ticks_msec() - _client_connect_time_ms
		if idle_ms > int(REQUEST_TIMEOUT_SECS * 1000):
			if _debug_verbose:
				print_rich("[color=yellow][DBridge] Client idle timeout (%.1fs)[/color]" % (idle_ms / 1000.0))
			_close_client()

func _close_client() -> void:
	if _client != null:
		_client.disconnect_from_host()
		_client = null
	_buffer = ""
	if _debug_verbose:
		print("[DBridge] Client disconnected")

func _process_commands() -> void:
	# Protect against buffer overflow
	if _buffer.length() > MAX_BUFFER_BYTES:
		print_rich("[color=red][DBridge] Buffer overflow, dropping client[/color]")
		_close_client()
		return
	# Process all complete JSON lines in the buffer
	while true:
		var newline_pos: int = _buffer.find("\n")
		if newline_pos < 0:
			break
		var line: String = _buffer.substr(0, newline_pos).strip_edges()
		_buffer = _buffer.substr(newline_pos + 1)
		if line.is_empty():
			continue
		_handle_request(line)

func _handle_request(line: String) -> void:
	if _debug_verbose:
		print("[DBridge RX] %s" % line)
	var json := JSON.new()
	if json.parse(line) != Error.OK:
		var err_response = {"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error: " + json.get_error_message()}}
		_send_response(err_response)
		print("[DBridge] Invalid JSON: %s" % json.get_error_message())
		return
	var data: Variant = json.data
	if not (data is Dictionary):
		print("[DBridge] Invalid request: not a dictionary")
		return
	var id: Variant = data.get("id", null)
	var method: String = str(data.get("method", ""))
	var params: Variant = data.get("params", {})
	if params is Array:
		var arr_response = _make_error(id, -32602, "Positional parameters not supported; use named parameters")
		_send_response(arr_response)
		return
	if params is String:
		# Some clients send params as string — re-parse
		var inner_json := JSON.new()
		if inner_json.parse(params) == Error.OK:
			params = inner_json.data

	var response: Dictionary
	if method.is_empty():
		response = _make_error(id, -32700, "Missing method")
	elif not _has_handler(method):
		response = _make_error(id, -32601, "Method not found: " + method)
	else:
		var handler_params: Dictionary = {}
		if params is Dictionary:
			handler_params = params.duplicate()
		handler_params["__id"] = id
		if method == "execute_lua":
			# Route through the same inline (main-thread) handler as the
			# registered _handlers entry. Runs the Lua on the main thread so
			# Lua-driven Godot calls (presentation, highlights, UI) work.
			response = await _cmd_execute_lua(handler_params)
		else:
			# await supports both sync handlers (returns their value directly) and
			# coroutine handlers like start_scene (polls across frames) without
			# special-casing. _handle_request becomes a coroutine; the single
			# in-flight command is processed sequentially by _process_commands.
			response = await _dispatch(method, handler_params)
		# Contract: handlers MUST return either a bare value or a partial envelope
		# {"result": ...} / {"error": ...} — never a full JSON-RPC envelope
		# ({"jsonrpc","id","result"}). A full envelope would carry id=null here and
		# get double-stamped, so we stamp the id only when it is missing/null and
		# set jsonrpc once, keeping a single authoritative envelope.
		if response.get("id", null) == null:
			response["id"] = id
		response["jsonrpc"] = "2.0"

	_send_response(response)
	if _debug_verbose:
		print("[DBridge TX] %s" % _json_dumps(response))

## Send a JSON-RPC notification (no id, no response expected).
## Used to push log messages to the client in real-time.
func _send_log_notification(text: String) -> void:
	if _client == null:
		return
	var data: PackedByteArray = (text + "\n").to_utf8_buffer()
	var put_err: Error = _client.put_data(data)
	_client.poll()

func _send_response(response: Dictionary) -> void:
	if _client == null:
		return
	var text: String = _json_dumps(response) + "\n"
	var data: PackedByteArray = text.to_utf8_buffer()
	var put_err: Error = _client.put_data(data)
	_client.poll()
	if _debug_verbose:
		print("[DBridge TX] put_err=%d bytes=%d" % [put_err, data.size()])

func _json_dumps(data: Variant) -> String:
	return JSON.stringify(data, "", false)

func _make_error(id: Variant, code: int, message: String) -> Dictionary:
	return {
		"jsonrpc": "2.0",
		"id": id,
		"error": {"code": code, "message": message},
	}

# --- Debug Log Collector ---
# Captures all Godot log output via OS.add_logger() and exposes it through the bridge.
# The collector is a separate class (debug_log_collector.gd) to avoid inner-class issues.

var _log_collector: Logger = null

var _handlers: Dictionary
var _debug_verbose: bool = false

# --- execute_lua single-flight guard ---
# execute_lua runs INLINE on the main thread (see _cmd_execute_lua). The Lua VM
# is single-threaded, so at most one eval runs at a time; a concurrent request
# gets a "busy" error. _lua_in_flight is set for the duration of the inline
# call to enforce this.
var _lua_in_flight: bool = false

## Extract node path from params, accepting both "path" and "node_path" keys.
func _get_node_path_param(params: Dictionary, default: String = "") -> String:
	if params.has("path"):
		return str(params["path"])
	if params.has("node_path"):
		return str(params["node_path"])
	return default


func _init_handlers() -> void:
	_handlers = {
		"ping":                _cmd_ping,
		"inspect_tree":        _cmd_inspect_tree,
		"get_property":        _cmd_get_property,
		"set_property":        _cmd_set_property,
		"emit_signal":         _cmd_emit_signal,
		"call_method":         _cmd_call_method,
		"screenshot":          _cmd_screenshot,
		"screenshot_base64":   _cmd_screenshot_base64,
		"inject_key":          _cmd_inject_key,
		"inject_mouse":        _cmd_inject_mouse,
		"list_signals":        _cmd_list_signals,
		"list_methods":        _cmd_list_methods,
		"find_nodes":          _cmd_find_nodes,
		"inspect_control":     _cmd_inspect_control,
		"scan_ui":             _cmd_scan_ui,
		"click_node":          _cmd_click_node,
		"press_button":        _cmd_press_button,
		"get_scene_info":      _cmd_get_scene_info,
		"set_time_scale":      _cmd_set_time_scale,
		"change_scene":        _cmd_change_scene,
		"start_scene":         _cmd_start_scene,
		"inject_input_event":  _cmd_inject_input_event,
		"graceful_quit":       _cmd_graceful_quit,
		"game_status":         _cmd_game_status,
		"execute_lua":         _cmd_execute_lua,
		"toggle_verbose":      _cmd_toggle_verbose,
		"list_handlers":       _cmd_list_handlers,
		"get_godot_logs":      _cmd_get_godot_logs,
		"clear_godot_logs":    _cmd_clear_godot_logs,
		"get_crashes":         _cmd_get_crashes,
		"clear_crashes":       _cmd_clear_crashes,
	}

func _init_log_collector() -> void:
	_log_collector = _LogCollectorScript.new()
	OS.add_logger(_log_collector)

## Clear in-memory log collector and truncate the log file at the start of each game run.
## This prevents log pollution from previous sessions.
func _clear_logs_for_session() -> void:
	_log_collector.clear_messages()
	var log_file: String = "/tmp/godot_output.log"
	var file := FileAccess.open(log_file, FileAccess.WRITE)
	if file != null:
		file.close()
	print("[DebugBridge] Log collector cleared for new session")

## Allow external autoloads (e.g., GameBridge) to register custom JSON-RPC handlers.
func register_handler(method_name: String, handler: Callable) -> void:
	_handlers[method_name] = handler

## Game-specific wiring: register the Lua engine used by execute_lua.
## The generic core knows nothing about which autoload provides it.
func set_lua_vm(lua_vm: Node) -> void:
	_lua_vm = lua_vm

func has_lua_vm() -> bool:
	return _lua_vm != null and is_instance_valid(_lua_vm)

func _has_handler(method: String) -> bool:
	return method in _handlers

## Dispatch a registered handler. A coroutine: `await`-ing the handler call supports
## both sync handlers (return their value directly) and async/coroutine handlers
## (e.g. start_scene) by resolving their result. ALL call sites must `await _dispatch`.
func _dispatch(method: String, params: Dictionary) -> Dictionary:
	return await _handlers[method].call(params)

func _resolve_node(path: String) -> Dictionary:
	"""Returns {node: Node} or {error: String}."""
	if path.is_empty() or path == "root":
		return {"node": get_tree().root}
	var full_path: String = "/root/" + path
	var node: Node = get_node_or_null(full_path)
	if node == null:
		return {"error": "Node not found: " + full_path}
	return {"node": node}

func _cmd_ping(_params: Dictionary) -> Dictionary:
	return {"result": {"pong": true, "port": _bound_port}}

func _cmd_inspect_tree(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", "root"))
	var depth: int = int(params.get("depth", 1))
	var node_result := _resolve_node(path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var node: Node = node_result["node"]
	var tree := _build_tree(node, depth)
	return {"result": tree}

func _build_tree(node: Node, remaining_depth: int) -> Dictionary:
	var result: Dictionary = {
		"path": _get_node_path(node),
		"node_name": node.name,
		"type": node.get_class(),
	}
	if remaining_depth > 0:
		var children: Array = []
		for child in node.get_children():
			children.append(_build_tree(child, remaining_depth - 1))
		result["children"] = children
	return result

func _get_node_path(node: Node) -> String:
	var path: String = str(get_tree().root.get_path_to(node))
	if path.is_empty():
		return "root"
	return path

# --- Helper utilities ---

func _has_property(node: Object, prop: String) -> bool:
	for p in node.get_property_list():
		if p["name"] == prop:
			return true
	return false

func _variant_to_serializable(v: Variant) -> Variant:
	"""Convert Godot variants to JSON-serializable types."""
	match typeof(v):
		TYPE_STRING: return str(v)
		TYPE_INT: return int(v)
		TYPE_FLOAT: return float(v)
		TYPE_BOOL: return bool(v)
		TYPE_VECTOR2: return {"x": float(v.x), "y": float(v.y)}
		TYPE_VECTOR2I: return {"x": int(v.x), "y": int(v.y)}
		TYPE_VECTOR3: return {"x": float(v.x), "y": float(v.y), "z": float(v.z)}
		TYPE_COLOR: return {"r": v.r, "g": v.g, "b": v.b, "a": v.a}
		TYPE_RECT2: return {"x": float(v.position.x), "y": float(v.position.y), "w": float(v.size.x), "h": float(v.size.y)}
		TYPE_VECTOR4: return {"x": float(v.x), "y": float(v.y), "z": float(v.z), "w": float(v.w)}
		TYPE_DICTIONARY:
			var dict_result: Dictionary = {}
			for key in v:
				dict_result[key] = _variant_to_serializable(v[key])
			return dict_result
		TYPE_ARRAY:
			var arr_result: Array = []
			for item in v:
				arr_result.append(_variant_to_serializable(item))
			return arr_result
		TYPE_STRING_NAME: return str(v)
		TYPE_NODE_PATH: return str(v)
		TYPE_PLANE: return str(v)
		TYPE_QUATERNION: return str(v)
		TYPE_PROJECTION: return str(v)
		TYPE_TRANSFORM2D: return str(v)
		TYPE_TRANSFORM3D: return str(v)
		TYPE_OBJECT:
			if v == null:
				return null
			return {"object_id": int(v.get_instance_id()), "class": str(v.get_class())}
		TYPE_NIL: return null
		_: return str(v)

func _deserialize_variant(value: Variant) -> Variant:
	"""Convert JSON-serializable dictionaries back to Godot types."""
	if not value is Dictionary:
		return value
	var d: Dictionary = value

	# Explicit type hints override automatic detection
	var type_hint: String = str(d.get("__type", ""))
	if type_hint == "dict" or type_hint == "hex" or type_hint == "raw":
		# Return as plain Dictionary, stripping the __type key
		var clean: Dictionary = d.duplicate()
		clean.erase("__type")
		return clean
	if type_hint == "vector2":
		return Vector2(float(d.get("x", 0)), float(d.get("y", 0)))
	if type_hint == "vector2i":
		return Vector2i(int(d.get("x", 0)), int(d.get("y", 0)))
	if type_hint == "array":
		return d.get("values", [])

	# Automatic detection (existing logic, unchanged)
	if "x" in d and "y" in d and "w" in d and "h" in d:
		return Rect2(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("w", 0)), float(d.get("h", 0)))
	if "x" in d and "y" in d and "z" in d and "w" in d:
		return Vector4(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("z", 0)), float(d.get("w", 0)))
	if "x" in d and "y" in d and "z" in d:
		return Vector3(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("z", 0)))
	if "x" in d and "y" in d:
		return Vector2(float(d.get("x", 0)), float(d.get("y", 0)))
	if "r" in d and "g" in d and "b" in d:
		return Color(float(d.get("r", 0)), float(d.get("g", 0)), float(d.get("b", 0)), float(d.get("a", 1)))
	if "x" in d and "y" in d and "z" in d and "d" in d:
		return Plane(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("z", 0)), float(d.get("d", 0)))
	return value

func _variant_type_name(v: Variant) -> String:
	match typeof(v):
		TYPE_STRING: return "String"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_BOOL: return "bool"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_COLOR: return "Color"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_ARRAY: return "Array"
		TYPE_STRING_NAME: return "StringName"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_OBJECT: return "Object"
		TYPE_NIL: return "null"
		_: return "unknown"

# --- Command handlers ---

func _cmd_get_property(params: Dictionary) -> Dictionary:
	var path: String = _get_node_path_param(params)
	var prop: String = str(params.get("prop", ""))
	var node_result := _resolve_node(path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var node: Node = node_result["node"]
	if not _has_property(node, prop):
		return _make_error(params.get("__id", null), -32602, "Property not found: " + prop + " on " + node.name)
	var value: Variant = node.get(prop)
	return {"result": {"value": _variant_to_serializable(value), "type": _variant_type_name(value)}}

func _cmd_set_property(params: Dictionary) -> Dictionary:
	var path: String = _get_node_path_param(params)
	var prop: String = str(params.get("prop", ""))
	var value: Variant = params.get("value", null)
	var node_result := _resolve_node(path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var node: Node = node_result["node"]
	if not _has_property(node, prop):
		return _make_error(params.get("__id", null), -32602, "Property not found: " + prop + " on " + node.name)
	var deserialized: Variant = _deserialize_variant(value)
	node.set(prop, deserialized)
	return {"result": {"ok": true}}

func _cmd_emit_signal(params: Dictionary) -> Dictionary:
	var path: String = _get_node_path_param(params)
	var signal_name: String = str(params.get("signal", ""))
	var args: Array = params.get("args", [])
	var node_result := _resolve_node(path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var node: Node = node_result["node"]
	if not node.has_signal(signal_name):
		return _make_error(params.get("__id", null), -32602, "Signal not found: " + signal_name + " on " + node.name)
	var deserialized_args: Array = []
	for arg in args:
		deserialized_args.append(_deserialize_variant(arg))
	node.callv("emit_signal", [signal_name] + deserialized_args)
	return {"result": {"ok": true}}

func _cmd_call_method(params: Dictionary) -> Dictionary:
	var path: String = _get_node_path_param(params)
	var method_name: String = str(params.get("method", ""))
	var args: Array = params.get("args", [])
	var node_result := _resolve_node(path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var node: Node = node_result["node"]
	if not node.has_method(method_name):
		return _make_error(params.get("__id", null), -32602, "Method not found: " + method_name + " on " + node.name)
	var deserialized_args: Array = []
	for arg in args:
		deserialized_args.append(_deserialize_variant(arg))
	var result: Variant = node.callv(method_name, deserialized_args)
	return {"result": {"value": _variant_to_serializable(result), "type": _variant_type_name(result)}}

func _cmd_screenshot(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", "user://debug_bridge_screenshot.png"))
	if not path.begins_with("user://"):
		return _make_error(params.get("__id", null), -32602, "Screenshot path must be in user:// directory")
	var image: Image = get_viewport().get_texture().get_image()
	var err: Error = image.save_png(path)
	if err == Error.OK:
		return {"result": {"ok": true, "path": path}}
	return _make_error(params.get("__id", null), -32000, "Screenshot failed to save to " + path + ": error %d" % err)

func _deserialize_input_event(data: Dictionary) -> InputEvent:
	"""Construct a Godot InputEvent from JSON data."""
	var event_type: String = str(data.get("type", ""))
	match event_type:
		"mouse_button":
			var event := InputEventMouseButton.new()
			event.button_index = int(data.get("button_index", 1)) as MouseButton
			event.pressed = bool(data.get("pressed", true))
			var pos_data: Dictionary = data.get("position", {"x": 0, "y": 0})
			event.position = _deserialize_variant(pos_data)
			event.global_position = event.position
			return event
		"mouse_motion":
			var event := InputEventMouseMotion.new()
			var pos_data: Dictionary = data.get("position", {"x": 0, "y": 0})
			event.position = _deserialize_variant(pos_data)
			event.global_position = event.position
			return event
		"key":
			var event := InputEventKey.new()
			event.keycode = int(data.get("keycode", 0)) as Key
			event.physical_keycode = event.keycode
			event.pressed = bool(data.get("pressed", true))
			return event
		_:
			return null

func _cmd_inject_key(params: Dictionary) -> Dictionary:
	var key_name: String = str(params.get("key", "")).to_upper()
	var pressed: bool = bool(params.get("pressed", true))

	var keycode: int = _key_string_to_code(key_name)
	if keycode == 0:
		return _make_error(params.get("__id", null), -32602, "Unknown key: " + key_name)

	var event := InputEventKey.new()
	event.keycode = keycode as Key
	event.physical_keycode = keycode as Key
	event.pressed = pressed
	event.shift_pressed = false
	event.ctrl_pressed = false
	event.alt_pressed = false
	event.meta_pressed = false

	get_viewport().push_input(event)
	return {"result": {"ok": true}}

func _cmd_inject_mouse(params: Dictionary) -> Dictionary:
	var action: String = str(params.get("action", "click"))
	var x: int = int(params.get("x", 0))
	var y: int = int(params.get("y", 0))
	var button_index: int = int(params.get("button", 1))
	var unhandled: bool = bool(params.get("unhandled", false))

	# Coordinate scaling
	var vp_width: int = ProjectSettings.get_setting("display/window/size/viewport_width", 800) as int
	var vp_height: int = ProjectSettings.get_setting("display/window/size/viewport_height", 1400) as int
	var vp_size := Vector2(float(vp_width), float(vp_height))
	var win_size: Vector2i = get_viewport().get_window().size
	var screen_pos := Vector2(
		float(x) * (win_size.x / vp_size.x),
		float(y) * (win_size.y / vp_size.y),
	)

	var push_fn: Callable
	if unhandled:
		push_fn = func(evt: InputEvent):
			evt.input_as_handled = false
			get_viewport().push_input(evt)
	else:
		push_fn = func(evt: InputEvent): get_viewport().push_input(evt)

	match action:
		"click":
			var press := InputEventMouseButton.new()
			press.button_index = button_index as MouseButton
			press.pressed = true
			press.position = screen_pos
			press.global_position = screen_pos
			push_fn.call(press)

			var release := InputEventMouseButton.new()
			release.button_index = button_index as MouseButton
			release.pressed = false
			release.position = screen_pos
			release.global_position = screen_pos
			push_fn.call(release)
		"move":
			var event := InputEventMouseMotion.new()
			event.position = screen_pos
			event.global_position = screen_pos
			event.shift_pressed = false
			event.ctrl_pressed = false
			event.alt_pressed = false
			event.meta_pressed = false
			push_fn.call(event)
		_:
			return _make_error(params.get("__id", null), -32602, "Unknown mouse action: " + action)

	return {"result": {"ok": true}}

func _key_string_to_code(key: String) -> int:
	match key:
		"ENTER": return KEY_ENTER
		"RETURN": return KEY_ENTER
		"ESCAPE": return KEY_ESCAPE
		"ESC": return KEY_ESCAPE
		"SPACE": return KEY_SPACE
		"TAB": return KEY_TAB
		"BACKSPACE": return KEY_BACKSPACE
		"DELETE": return KEY_DELETE
		"INSERT": return KEY_INSERT
		"HOME": return KEY_HOME
		"END": return KEY_END
		"PAGEUP": return KEY_PAGEUP
		"PAGEDOWN": return KEY_PAGEDOWN
		"UP": return KEY_UP
		"DOWN": return KEY_DOWN
		"LEFT": return KEY_LEFT
		"RIGHT": return KEY_RIGHT
		"F1": return KEY_F1
		"F2": return KEY_F2
		"F3": return KEY_F3
		"F4": return KEY_F4
		"F5": return KEY_F5
		"F6": return KEY_F6
		"F7": return KEY_F7
		"F8": return KEY_F8
		"F9": return KEY_F9
		"F10": return KEY_F10
		"F11": return KEY_F11
		"F12": return KEY_F12
		"SHIFT": return KEY_SHIFT
		"CTRL": return KEY_CTRL
		"CONTROL": return KEY_CTRL
		"ALT": return KEY_ALT
		"META": return KEY_META
		"CAPSLOCK": return KEY_CAPSLOCK
		"NUMLOCK": return KEY_NUMLOCK
		"PRINT": return KEY_PRINT
		"PAUSE": return KEY_PAUSE
		_:
			if key.length() == 1:
				var c: String = key[0]
				return c.unicode_at(0)
			return 0

func _cmd_list_signals(params: Dictionary) -> Dictionary:
	var path: String = _get_node_path_param(params)
	var node_result := _resolve_node(path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var node: Node = node_result["node"]
	var signals: Array = []
	for sig in node.get_signal_list():
		signals.append(str(sig["name"]))
	return {"result": signals}

func _cmd_list_methods(params: Dictionary) -> Dictionary:
	var path: String = _get_node_path_param(params)
	var pattern: String = str(params.get("pattern", ""))
	var node_result := _resolve_node(path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var node: Node = node_result["node"]
	var methods: Array = []
	for m in node.get_method_list():
		var method_name: String = str(m["name"])
		if pattern.is_empty() or method_name.findn(pattern) >= 0:
			methods.append(method_name)
	return {"result": methods}

# --- New command handlers (Task 2) ---

func _cmd_screenshot_base64(params: Dictionary) -> Dictionary:
	var image: Image = get_viewport().get_texture().get_image()
	var scale: float = clampf(float(params.get("scale", 1.0)), 0.1, 4.0)
	if scale != 1.0:
		image.resize(int(image.get_width() * scale),
					 int(image.get_height() * scale))
	var bytes: PackedByteArray = image.save_png_to_buffer()
	var b64: String = Marshalls.raw_to_base64(bytes)
	return {"result": {"base64_png": b64,
					   "width": image.get_width(),
					   "height": image.get_height()}}

func _cmd_get_scene_info(_params: Dictionary) -> Dictionary:
	var root := get_tree().current_scene
	var scene_name: Variant
	var scene_file: Variant
	if root != null:
		scene_name = root.name
		scene_file = root.scene_file_path
	return {"result": {
		"scene_name": scene_name,
		"scene_file": scene_file,
		"viewport_size": {
			"w": get_viewport().get_visible_rect().size.x,
			"h": get_viewport().get_visible_rect().size.y,
		},
		"paused": get_tree().paused,
		"fps": Engine.get_frames_per_second(),
	}}

func _cmd_inspect_control(params: Dictionary) -> Dictionary:
	var path: String = _get_node_path_param(params)
	var node_result := _resolve_node(path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var node: Node = node_result["node"]
	if not node is Control:
		return _make_error(params.get("__id", null), -32602, "Node is not a Control: " + path)
	var ctrl := node as Control
	var rect: Rect2 = ctrl.get_global_rect()
	var center := rect.get_center()
	var disabled: bool = false
	if ctrl.has_method("is_disabled"):
		disabled = ctrl.is_disabled()
	var text: Variant = null
	if _has_property(ctrl, "text"):
		text = ctrl.get("text")
	return {"result": {
		"path": _get_node_path(ctrl),
		"type": ctrl.get_class(),
		"visible": ctrl.visible,
		"disabled": disabled,
		"text": _variant_to_serializable(text),
		"rect": {"x": rect.position.x, "y": rect.position.y,
				 "w": rect.size.x, "h": rect.size.y},
		"center": {"x": center.x, "y": center.y},
	}}

func _cmd_scan_ui(params: Dictionary) -> Dictionary:
	var root_path: String = str(params.get("root", "root"))
	var type_filter: Array = params.get("types", [])
	var node_result := _resolve_node(root_path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var root: Node = node_result["node"]
	var controls: Array = []
	_collect_controls(root, type_filter, controls)
	return {"result": controls}

func _collect_controls(node: Node, type_filter: Array, results: Array) -> void:
	if node is Control:
		if not node.visible:
			return  # skip invisible node and its entire subtree
		var ctrl := node as Control
		var node_type: String = ctrl.get_class()
		if not type_filter.is_empty() and node_type not in type_filter:
			# Filtered out — recurse children but don't append this node
			for child in node.get_children():
				_collect_controls(child, type_filter, results)
			return
		var rect: Rect2 = ctrl.get_global_rect()
		var center := rect.get_center()
		var disabled: bool = false
		if ctrl.has_method("is_disabled"):
			disabled = ctrl.is_disabled()
		var text: Variant = null
		if _has_property(ctrl, "text"):
			text = ctrl.get("text")
		var entry: Dictionary = {
			"path": _get_node_path(ctrl),
			"type": node_type,
			"visible": ctrl.visible,
			"disabled": disabled,
			"text": _variant_to_serializable(text),
			"rect": {"x": rect.position.x, "y": rect.position.y,
					 "w": rect.size.x, "h": rect.size.y},
			"center": {"x": center.x, "y": center.y},
		}
		results.append(entry)
	for child in node.get_children():
		_collect_controls(child, type_filter, results)

# --- Task 3: new command handlers ---

func _cmd_set_time_scale(params: Dictionary) -> Dictionary:
	var scale: float = maxf(float(params.get("scale", 1.0)), 0.0)
	Engine.time_scale = scale
	return {"result": {"ok": true, "time_scale": Engine.time_scale}}

## Change scene from the MAIN thread. Unlike execute_lua (which runs on a
## background thread after the wedge fix), this handler runs on the game's main
## thread via _process_commands, so get_tree().change_scene_to_file() works.
## Game-specific: callers typically set a match/config on a session autoload
## first (via `game set`), then change-scene to the scene that reads it.
func _cmd_change_scene(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	if path.is_empty():
		return _make_error(params.get("__id", null), -32602, "scene path required (pass 'path' parameter)")
	var ok: Error = get_tree().change_scene_to_file(path)
	if ok != OK:
		return _make_error(params.get("__id", null), -32601, "change_scene_to_file failed: " + error_string(ok))
	return {"result": {"ok": true, "scene": path}}

## Generic: change scene then poll a readiness probe across frames until true
## or timeout. Probe forms (no game knowledge):
##   {node: "/root/X"}                       -> node exists + is_instance_valid
##   {node: "/root/X", prop: "p", equals: v} -> node exists and get(p) == v
##   {handler: "my_probe"}                   -> call registered handler, read its bool
func _cmd_start_scene(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	if path.is_empty():
		return _make_error(params.get("__id", null), -32602, "scene path required (pass 'path' parameter)")
	var probe: Dictionary = {}
	if params.has("ready_probe"):
		probe = params["ready_probe"]
	if not (probe is Dictionary) or probe.is_empty():
		return _make_error(params.get("__id", null), -32602, "ready_probe required: {node} | {node,prop,equals} | {handler}")
	var timeout_s: float = float(params.get("timeout_s", 8.0))
	var poll_ms: int = int(params.get("poll_ms", 100))

	var change_ok: Error = get_tree().change_scene_to_file(path)
	if change_ok != OK:
		return _make_error(params.get("__id", null), -32601, "change_scene_to_file failed: " + error_string(change_ok))

	var start_ms: int = Time.get_ticks_msec()
	var waited_ms: int = 0
	var last_probe: Variant = null
	var ready: bool = false
	var poll_s: float = maxf(float(poll_ms) / 1000.0, 0.016)
	while true:
		await get_tree().create_timer(poll_s).timeout
		last_probe = await _eval_probe(probe)
		ready = (last_probe == true)
		waited_ms = Time.get_ticks_msec() - start_ms
		if ready or waited_ms >= int(timeout_s * 1000.0):
			break
	return {"result": {"scene": path, "ready": ready, "waited_ms": waited_ms, "probe": last_probe}}

## Evaluate a readiness probe. Returns true/false.
## A coroutine: `await`-ing _dispatch supports both sync probe handlers (return their
## value directly) and async probe handlers (poll Lua/state across frames). The probe
## handler should return a bool or {"live": bool} / {"ready": bool}.
func _eval_probe(probe: Dictionary) -> bool:
	if probe.has("handler"):
		var hname: String = str(probe["handler"])
		if not _has_handler(hname):
			return false
		var res: Variant = await _dispatch(hname, {})
		if res is Dictionary:
			var r: Dictionary = res
			if r.has("result"):
				var inner: Variant = r["result"]
				if inner is Dictionary and inner.has("live"):
					return (inner["live"] is bool) and inner["live"]
				if inner is Dictionary and inner.has("ready"):
					return (inner["ready"] is bool) and inner["ready"]
				if inner is bool:
					return inner
			if r.has("error"):
				return false
		# Bare bool result (e.g. a probe returning true/false directly).
		# Only compare when res is actually a bool; anything else (Dictionary,
		# null, Number) is not-ready. (GDScript 4.x rejects == between
		# incompatible types, so the type guard is required.)
		if res is bool:
			return res
		return false
	# node-based probe
	var node_path: String = str(probe.get("node", ""))
	if node_path.is_empty():
		return false
	var node: Node = get_node_or_null(node_path)
	if node == null or not is_instance_valid(node):
		return false
	if probe.has("prop"):
		var prop: String = str(probe["prop"])
		if not node.has_property(prop):
			return false
		return node.get(prop) == probe.get("equals")
	return true

func _cmd_find_nodes(params: Dictionary) -> Dictionary:
	var root_path: String = str(params.get("root", "root"))
	var name_pattern: String = str(params.get("name_pattern", "*"))
	var node_type: String = str(params.get("type", ""))
	var recursive: bool = bool(params.get("recursive", true))
	var owned: bool = bool(params.get("owned", false))

	var node_result := _resolve_node(root_path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var root: Node = node_result["node"]

	var children: Array = root.find_children(name_pattern, node_type, recursive, owned)
	var results: Array = []
	for child in children:
		results.append({
			"path": _get_node_path(child),
			"name": child.name,
			"type": child.get_class(),
		})
	return {"result": results}

func _cmd_click_node(params: Dictionary) -> Dictionary:
	var path: String = _get_node_path_param(params)
	var button_index: int = int(params.get("button", 1))
	var node_result := _resolve_node(path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var node: Node = node_result["node"]
	if not node is Control:
		return _make_error(params.get("__id", null), -32602, "Node is not a Control: " + path)
	var ctrl := node as Control
	var rect: Rect2 = ctrl.get_global_rect()
	var center := rect.get_center()

	# get_global_rect() returns viewport coordinates; push_input() expects screen coordinates.
	var vp_width: int = ProjectSettings.get_setting("display/window/size/viewport_width", 800) as int
	var vp_height: int = ProjectSettings.get_setting("display/window/size/viewport_height", 1400) as int
	var vp_size := Vector2(float(vp_width), float(vp_height))
	var win_size: Vector2i = get_viewport().get_window().size
	var screen_center := Vector2(
		center.x * (win_size.x / vp_size.x),
		center.y * (win_size.y / vp_size.y),
	)

	# Press
	var event_press := InputEventMouseButton.new()
	event_press.button_index = button_index as MouseButton
	event_press.pressed = true
	event_press.position = screen_center
	event_press.global_position = screen_center
	get_viewport().push_input(event_press)

	# Release
	var event_release := InputEventMouseButton.new()
	event_release.button_index = button_index as MouseButton
	event_release.pressed = false
	event_release.position = screen_center
	event_release.global_position = screen_center
	get_viewport().push_input(event_release)

	return {"result": {"ok": true, "path": _get_node_path(ctrl),
					   "center": {"x": center.x, "y": center.y}}}

func _cmd_press_button(params: Dictionary) -> Dictionary:
	var path: String = _get_node_path_param(params)
	var node_result := _resolve_node(path)
	if "error" in node_result:
		return _make_error(params.get("__id", null), -32602, node_result["error"])
	var node: Node = node_result["node"]
	if not node is Button:
		return _make_error(params.get("__id", null), -32602, "Node is not a Button: " + path)
	(node as Button).emit_signal("pressed")
	return {"result": {"ok": true, "path": path}}

func _cmd_inject_input_event(params: Dictionary) -> Dictionary:
	var target_path: String = params.get("target", _get_node_path_param(params))
	var event_data: Dictionary = params.get("event", {})

	var target_result := _resolve_node(target_path)
	if "error" in target_result:
		return _make_error(params.get("__id", null), -32602, target_result["error"])
	var target: Node = target_result["node"]

	var event: InputEvent = _deserialize_input_event(event_data)
	if event == null:
		return _make_error(params.get("__id", null), -32602, "Cannot construct input event from: " + str(event_data))

	target.call("_unhandled_input", event)
	return {"result": {"ok": true, "event_type": event.get_class()}}

func _cmd_graceful_quit(_params: Dictionary) -> Dictionary:
	get_tree().quit()
	return {"result": {"ok": true}}

func _cmd_game_status(_params: Dictionary) -> Dictionary:
	var root = get_tree().current_scene
	var scene_name: Variant
	var scene_file: Variant
	if root != null:
		scene_name = root.name
		scene_file = root.scene_file_path
	var in_combat: bool = get_node_or_null("/root/Main") != null
	return {"result": {
		"scene_name": scene_name,
		"scene_file": scene_file,
		"port": _bound_port,
		"in_combat": in_combat,
	}}

# --- execute_lua (main-thread) --------------------------------------------
## Handler entry point (kept in _init_handlers). Runs the Lua INLINE on the
## MAIN thread. This is correct: combat actions (targeting, highlights,
## animation presentation, UI) call Godot node methods that MUST run on the
## main thread — a background thread makes them fail with "The caller thread
## can't call the function on this node". The old background-thread "wedge
## fix" is retired: it wedged because the editor proxy timeout was 10s while a
## long turn blocked the main thread; that timeout is now 120s and the editor's
## heartbeat is independent of the game, so a normal turn (a few seconds)
## completes well within the deadline and the response is delivered inline.
## A concurrent request is still rejected (single-flight Lua VM).
func _cmd_execute_lua(params: Dictionary) -> Dictionary:
	var id: Variant = params.get("__id", null)
	var code: String = str(params.get("code", ""))
	if code.is_empty():
		return _make_error(id, -32602, "Lua code string required (pass 'code' parameter)")
	if _lua_in_flight:
		return _make_error(id, -32001, "execute_lua busy: a previous call is still running")
	if not has_lua_vm():
		return _make_error(id, -32602,
			"no Lua engine registered (call DebugBridge.set_lua_vm(node))")

	_lua_in_flight = true
	var out: Dictionary = _run_lua_wrapped(_lua_vm, code)
	_lua_in_flight = false

	if out.get("error", "") != "":
		var resp: Dictionary = _make_error(id, -32000,
			(str(out.get("error_kind", "lua")) + " error: ") + str(out["error"]))
		resp["result"] = {"stdout": out.get("stdout", "")}
		return resp
	return {"jsonrpc": "2.0", "id": id,
		"result": {"value": _variant_to_serializable(out.get("value", null)),
			"type": _variant_type_name(out.get("value", null)),
			"stdout": out.get("stdout", "")}}

## Run Lua code (synchronously, on the calling thread) wrapped so that:
##  - Lua `print()` output is captured into the returned "stdout" (a plain
##    print from a non-UI context is unreliable; capture makes it deterministic).
##  - Any Lua error is caught and reported (not a crash), with "error_kind".
##  - A clean `return nil` is distinguished from an error.
## Returns {value=..., stdout=..., error=..., error_kind=...}.
## The prelude + user code + epilogue MUST be ONE execute_string chunk: `lua.
## do_string` does not persist a global `print` override across separate calls.
func _run_lua_wrapped(lua_vm: Node, code: String) -> Dictionary:
	var wrapped: String = "local _orig_print = print local _cap = {} local _cn = 0 "
	wrapped = wrapped + "print = function(...) _cn = _cn + 1 local p = {} "
	wrapped = wrapped + "for i = 1, select('#', ...) do p[i] = tostring(select(i, ...)) end "
	wrapped = wrapped + "table.insert(_cap, table.concat(p, ' ')) "
	wrapped = wrapped + "if _cn >= 5000 then print = _orig_print return end end "
	wrapped = wrapped + "local function _run() "
	wrapped = wrapped + code
	wrapped = wrapped + " end "
	wrapped = wrapped + "local ok, val = pcall(_run) "
	wrapped = wrapped + "local err = '' if not ok then err = tostring(val) end "
	wrapped = wrapped + "print = _orig_print "
	wrapped = wrapped + "return { value = ok and val or nil, stdout = table.concat(_cap, '\\n'), error = err }"

	var r: Variant = lua_vm.call("execute_string", wrapped)

	var out: Dictionary = {"value": null, "stdout": "", "error": "", "error_kind": "lua"}
	if r is Object and r.get_class() == "LuaError":
		out["error"] = "wrapper failed: " + str(r.message)
		return out

	var table_d: Dictionary = {}
	if r is Dictionary:
		table_d = r
	elif r is Array:
		table_d = {}

	out["stdout"] = str(table_d.get("stdout", ""))
	var err_s: String = str(table_d.get("error", ""))
	out["value"] = table_d.get("value", null)
	if err_s != "":
		out["error"] = err_s
		out["error_kind"] = "lua"
	return out

func _cmd_toggle_verbose(params: Dictionary) -> Dictionary:
	var new_value: bool = ! _debug_verbose
	_debug_verbose = new_value
	return {"result": {"verbose": _debug_verbose}}

func _cmd_list_handlers(_params: Dictionary) -> Dictionary:
	var handlers: Array = []
	for key in _handlers:
		handlers.append(key)
	handlers.sort()
	return {"result": {"handlers": handlers}}

func _cmd_get_godot_logs(params: Dictionary) -> Dictionary:
	if _log_collector == null:
		return _make_error(params.get("__id", null), -32602, "Log collector not initialized")

	var from_index: int = int(params.get("from", 0))
	var max_lines: int = int(params.get("max_lines", 5000))

	var messages: Array[String] = _log_collector.get_messages()
	var total: int = messages.size()

	# Clamp from_index to valid range
	if from_index < 0:
		from_index = 0
	if from_index > total:
		from_index = total

	var end: int = min(from_index + max_lines, total)
	var slice: Array[String] = messages.slice(from_index, end)

	return {"result": {
		"messages": slice,
		"total_lines": total,
		"from": from_index,
		"count": slice.size(),
	}}

func _cmd_clear_godot_logs(params: Dictionary) -> Dictionary:
	if _log_collector == null:
		return _make_error(params.get("__id", null), -32602, "Log collector not initialized")

	_log_collector.clear_messages()
	return {"result": {"ok": true}}

## Return recent crash/error entries + a crash_detected flag, so a crash can be
## read without dumping the whole log. Complements the DAP `debugger state`
## (breaked=true often means a crash/exception).
func _cmd_get_crashes(params: Dictionary) -> Dictionary:
	if _log_collector == null:
		return _make_error(params.get("__id", null), -32602, "Log collector not initialized")
	var max_lines: int = int(params.get("max_lines", 50))
	return {"result": _log_collector.get_crashes(max_lines)}

func _cmd_clear_crashes(_params: Dictionary) -> Dictionary:
	if _log_collector == null:
		return _make_error(_params.get("__id", null), -32602, "Log collector not initialized")
	_log_collector.reset_crash()
	return {"result": {"ok": true}}

func _exit_tree() -> void:
	if _poll_timer != null:
		_poll_timer.stop()
	if _client != null:
		_client.disconnect_from_host()
	if _server != null:
		_server.stop()
