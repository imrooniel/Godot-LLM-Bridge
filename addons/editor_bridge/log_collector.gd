@tool
extends Logger

## Editor-process log collector.
##
## Captures editor prints and script/engine errors via OS.add_logger().
## (The game runs in a separate process — its output only reaches the
## editor's Output panel, not this collector.)
##
## Lines land in two places:
##   - a ring buffer (MAX_LINES) for `logs.get --source collector`
##   - a pending queue, drained by the core each poll tick for
##     `log` event streaming to subscribers

const MAX_LINES := 5000

var _messages: Array[String] = []
var _pending: Array[String] = []
var _mutex := Mutex.new()


func _log_message(message: String, error: bool) -> void:
	var level: String = "ERR" if error else "LOG"
	_record("[%s] %s" % [_timestamp(), message], level)


func _log_error(
		function_: String,
		file: String,
		line: int,
		_code: String,
		rationale: String,
		_editor_notify: bool,
		_error_type: int,
		script_backtraces: Array[ScriptBacktrace]
) -> void:
	var location: String = ""
	if not file.is_empty():
		location = " (%s:%d)" % [file, line]
	if not function_.is_empty():
		location = " at %s%s" % [function_, location]

	var bt_text: String = ""
	for bt: ScriptBacktrace in script_backtraces:
		if bt == null:
			continue
		for frame_idx in range(bt.get_frame_count()):
			bt_text += "\n    at %s in %s:%d" % [
				bt.get_frame_function(frame_idx),
				bt.get_frame_file(frame_idx),
				bt.get_frame_line(frame_idx),
			]

	_record("[%s] ERROR%s %s%s" % [_timestamp(), location, rationale, bt_text], "ERROR")


func _record(entry: String, _level: String) -> void:
	_mutex.lock()
	_messages.append(entry)
	if _messages.size() > MAX_LINES:
		_messages.remove_at(0)
	_pending.append(entry)
	_mutex.unlock()


func _timestamp() -> String:
	return "%.3f" % (Time.get_ticks_msec() / 1000.0)


func get_messages() -> Array[String]:
	_mutex.lock()
	var result: Array[String] = _messages.duplicate()
	_mutex.unlock()
	return result


## Drain and return all lines queued since the last call (event streaming).
func flush_pending() -> Array[String]:
	_mutex.lock()
	var result: Array[String] = _pending.duplicate()
	_pending.clear()
	_mutex.unlock()
	return result


func clear_messages() -> void:
	_mutex.lock()
	_messages.clear()
	_mutex.unlock()
