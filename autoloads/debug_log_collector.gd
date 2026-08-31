class_name DebugLogCollector
extends Logger

## Collects Godot engine log output and exposes it through the DebugBridge.
## Registered via OS.add_logger() in debug_bridge.gd.
##
## Thread-safe: Logger callbacks fire from non-main threads. All shared state
## is protected by _mutex. Pending push notifications are flushed on the main
## thread by DebugBridge._poll_socket() calling flush_pending().

var _messages: Array[String] = []
var _max_lines: int = 5000
var _mutex: Mutex
var _pending_notifications: Array[String] = []
## Cap for the pending-notification queue (VA#12): notifications are only
## drained while a DebugBridge client is connected, so without a cap the queue
## would grow unbounded for a long session. Oldest entries are dropped first.
var _max_pending: int = 1000

func _init() -> void:
	_mutex = Mutex.new()

func _log_message(message: String, error: bool) -> void:
	var level: String = "ERR" if error else "LOG"
	var timestamp: String = "%.3f" % (Time.get_ticks_msec() / 1000.0)
	var entry: String = "[%s] [%s] %s" % [timestamp, level, message]

	_mutex.lock()
	_messages.append(entry)
	_append_pending(_format_notification("log", entry))
	if _messages.size() > _max_lines:
		_messages.remove_at(0)
	_mutex.unlock()

func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		editor_notify: bool,
		error_type: int,
		script_backtraces: Array
) -> void:
	var timestamp: String = "%.3f" % (Time.get_ticks_msec() / 1000.0)
	var location: String = ""
	if not file.is_empty():
		location = " (%s:%d)" % [file, line]
	if not function.is_empty():
		location = " at %s%s" % [function, location]

	# Build backtrace text from script_backtraces (GDScript 4.5+)
	var bt_text: String = ""
	for bt: Variant in script_backtraces:
		if bt == null:
			continue
		var frames: Array = bt.get_frames() if bt.has_method("get_frames") else []
		for frame: Variant in frames:
			if frame == null:
				continue
			bt_text += "\n    at %s in %s ()" % [
				frame.get("source", "?"),
				frame.get("function", "?"),
			]

	var entry: String = "[%s] [%s]%s %s%s" % [timestamp, _error_label(error_type), location, _error_details(code, rationale), bt_text]

	_mutex.lock()
	_messages.append(entry)
	_append_pending(_format_notification("error", entry))
	if _messages.size() > _max_lines:
		_messages.remove_at(0)
	_mutex.unlock()

func get_messages() -> Array[String]:
	_mutex.lock()
	var result: Array[String] = _messages.duplicate()
	_mutex.unlock()
	return result

func clear_messages() -> void:
	_mutex.lock()
	_messages.clear()
	_mutex.unlock()

## Append a pending notification, dropping the oldest when over the cap.
## Must be called with _mutex held.
func _append_pending(notification: String) -> void:
	_pending_notifications.append(notification)
	if _pending_notifications.size() > _max_pending:
		_pending_notifications.remove_at(0)

## Message text for a logged error. Godot routes push_error()/push_warning()
## and script-error message text through `code` (rationale carries optional
## detail), so rationale is used only when non-empty — mirroring the engine's
## own logger (core/io/logger.cpp Logger::log_error).
func _error_details(code: String, rationale: String) -> String:
	if not rationale.is_empty():
		return rationale
	return code

## Severity label from the Logger::ErrorType value (core/io/logger.h):
## 0 = ERROR, 1 = WARNING, 2 = SCRIPT ERROR, 3 = SHADER ERROR.
func _error_label(error_type: int) -> String:
	match error_type:
		Logger.ERROR_TYPE_ERROR:
			return "ERROR"
		Logger.ERROR_TYPE_WARNING:
			return "WARNING"
		Logger.ERROR_TYPE_SCRIPT:
			return "SCRIPT ERROR"
		Logger.ERROR_TYPE_SHADER:
			return "SHADER ERROR"
	return "ERROR"

## Returns pending notification strings and clears the queue.
## Called from DebugBridge._poll_socket() on the main thread.
func flush_pending() -> Array[String]:
	_mutex.lock()
	var result: Array[String] = _pending_notifications.duplicate()
	_pending_notifications.clear()
	_mutex.unlock()
	return result

func _format_notification(type: String, message: String) -> String:
	var data: Dictionary = {
		"jsonrpc": "2.0",
		"method": "log_message",
		"params": {"type": type, "message": message},
	}
	return JSON.stringify(data, "", false)
