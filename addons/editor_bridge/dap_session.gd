@tool
extends RefCounted

## Persistent DAP (Debug Adapter Protocol) client.
##
## Godot 4.8 ships a DAP server inside the editor (DebugAdapterServer,
## built-in plugin, default 127.0.0.1:6006 — the VS Code debug protocol).
## This client owns ONE long-lived connection for the whole editor session:
##
##   - Serial request queue (one in flight; DAP latency is sub-millisecond
##     over loopback, so serialization costs nothing and ordering is trivial)
##   - Mailbox-driven: enqueue(mailbox_id, command, args); the matching DAP
##     response is written to the outbox. Some DAP requests are async on the
##     server side (launch, evaluate, variable expansion, stack dumps) — no
##     response is sent until the data arrives; the client just waits.
##     Command scripts that enqueue return null (async mailbox response).
##   - Events forwarded as bridge events: debugger_stopped / debugger_continued
##     / debugger_output / debugger_terminated / debugger_exited /
##     debugger_breakpoint / debugger_custom / debugger_dap (connect state)
##   - Keepalive: the server rejects a request arriving >5 s after the last
##     client data (process_message timeout), so a `threads` request goes out
##     every ~4 s
##   - Auto-reconnect if the socket drops while a game session is active
##   - Handshake: initialize (on connect) -> attach -> configurationDone
##
## Note: a NEW DAP client's `initialize` CLEARS all editor breakpoints unless
## the editor setting network/debug_adapter/sync_breakpoints is true (the core
## enables it at startup, which makes initialize re-announce existing
## breakpoints instead). That is why exactly ONE DAP client exists.

signal state_changed

var peer: StreamPeerTCP
var port: int = 6006
var _bridge = null  # core (EditorPlugin) — set via setup()

enum Phase { DISCONNECTED, CONNECTING, READY }
var phase: int = Phase.DISCONNECTED

var attached: bool = false   # DAP session bound to an active game session
var breaked: bool = false    # game paused (stopped seen, no continued yet)
var _want_attached: bool = false
var _game_active: bool = false

## Most recent `stopped` event detail (reason/text), so the CLI can surface the
## pause reason in state.json without a separate RPC. Cleared on continued /
## game stop. reason is one of: "paused" | "exception" | "breakpoint" | "step"
## (engine: debug_adapter_parser.cpp ev_stopped_*). For "exception" the engine
## puts the actual error message in `text`.
var last_stopped: Dictionary = {}

var _pending: Dictionary = {}    # seq -> mailbox_id ("" = internal request)
var _seq: int = 0
var _queue: Array = []           # {id, command, args, ...} waiting to send
var _in_flight: Dictionary = {}  # currently sent request

## Project root as an absolute OS path (for normalizing server-reported paths).
var _proj_prefix: String = ""

## The server reports ABSOLUTE OS paths; bookkeeping is keyed on res://.
## res:// paths (e.g. editor-UI-set breakpoints echoed back) pass through.
func _norm_path(p: String) -> String:
	if _proj_prefix != "" and p.begins_with(_proj_prefix):
		return "res://" + p.substr(_proj_prefix.length())
	return p

# TX tail buffer: 4.8-dev put_data() BLOCKS until the whole payload is sent
# (write() loops with poll(IN, -1) on ERR_BUSY) — in a same-process setup
# (the DAP server runs in THIS editor) that deadlocks the main loop whenever
# the peer can't drain. put_partial_data() is the non-blocking variant
# (p_block=false), so we send it and retry any tail on the next tick.
var _tx_pending: PackedByteArray = PackedByteArray()
var _tx_item: Dictionary = {}

# Breakpoint bookkeeping: "res://path" -> {line(int): verified(bool)}
var breakpoints: Dictionary = {}

# Output ring buffer (DAP `output` events)
const OUTPUT_MAX := 1000
var output_lines: Array = []

# DAP frames: "Content-Length: N\r\n\r\n" + N bytes of JSON (UTF-8).
# Byte-level framing (Content-Length is BYTES — no char/byte ambiguity).
# NOTE: 4.8-dev StreamPeer API: put_data(bytes) -> Error;
# get_data(n) -> [Error, PackedByteArray]. PackedByteArray.find() takes a
# single byte; get_string_from_*() take no args (whole buffer).
var _rx: PackedByteArray = PackedByteArray()
var _last_send_ms: int = 0
const KEEPALIVE_MS := 4000
const _MAX_RX: int = 4194304  # DAP_MAX_BUFFER_SIZE in the server

var _reconnect_at_ms: int = 0
var _initialized_seen: bool = false
var _config_done_queued: bool = false

# Lightweight wire diagnostics surfaced in get_state() (diag_* keys). Keep the
# footprint small: counters + a 12-entry ring of transition/send notes.
var _diag_rx_bytes: int = 0
var _diag_frames: int = 0
var _diag_last_msg: String = ""
var _diag_sends: int = 0
var _diag_log: Array = []  # ring of last 12 transition/send notes


func _diag_note(s: String) -> void:
	_diag_log.append(s)
	if _diag_log.size() > 12:
		_diag_log = _diag_log.slice(_diag_log.size() - 12)


func setup(bridge, p_port: int) -> void:
	_bridge = bridge
	port = p_port
	peer = StreamPeerTCP.new()
	_proj_prefix = ProjectSettings.globalize_path("res://")


# ---------------------------------------------------------------------------
# Request API (called from command scripts via ctx.dap)
# ---------------------------------------------------------------------------

## Force a connect attempt on the next tick (closes the race between
## game_started and the first debugger command).
func wake() -> void:
	_reconnect_at_ms = 0


func _connectable() -> bool:
	# Queueing while CONNECTING is safe: the pump starts when READY.
	return phase == Phase.READY or phase == Phase.CONNECTING


## Queue a DAP request. Returns false when disconnected (caller should call
## wake() first or error out). The matching response is written to the
## outbox for mailbox_id.
func enqueue(mailbox_id: String, command: String, args: Dictionary) -> bool:
	if not _connectable():
		return false
	_queue.append({"id": mailbox_id, "command": command, "args": args})
	return true


## Attach to the editor's active game session. The mailbox response arrives
## when the attach response is processed. `post` (optional) is a fully-formed
## queue item sent after attach succeeds (before configurationDone) — used to
## chain e.g. setBreakpoints behind an implicit attach.
func attach(mailbox_id: String, post: Dictionary = {}) -> bool:
	if not _connectable() or attached:
		return false
	_want_attached = true
	_config_done_queued = false
	_queue.append({"id": mailbox_id, "command": "attach", "args": {}, "hs_attach": true, "post": post})
	return true


## Launch a game through DAP (EditorRunBar). The server holds the launch
## until configurationDone; the mailbox response arrives after that.
func launch(mailbox_id: String, scene: String, play_args: Array, no_debug: bool) -> bool:
	if not _connectable() or attached:
		return false
	var args: Dictionary = {}
	if scene != "":
		args["scene"] = scene
	if play_args.size() > 0:
		args["playArgs"] = play_args
	if no_debug:
		args["noDebug"] = true
	_want_attached = true
	_config_done_queued = false
	_queue.append({"id": mailbox_id, "command": "launch", "args": args, "hs_launch": true})
	# Normal case: `initialized` already arrived -> queue configurationDone now
	# (it must follow the launch item). Rare race (launch before initialized):
	# the `initialized` event handler queues it instead.
	if _initialized_seen:
		_queue_config_done()
	return true


## Detach (DAP `disconnect`; a no-op on the game for attached peers).
func detach(mailbox_id: String) -> bool:
	if not _connectable() or not attached:
		return false
	_queue.append({"id": mailbox_id, "command": "disconnect", "args": {}, "hs_detach": true})
	return true


## Set ALL breakpoints for one source file (DAP replaces per-source list).
## `file` is a res:// path; the server's is_valid_path() requires an ABSOLUTE
## OS path (begins_with get_resource_path()), so the wire gets the
## globalized form while our bookkeeping keeps the res:// form.
func set_breakpoints(mailbox_id: String, file: String, lines: Array) -> bool:
	if not _connectable():
		return false
	var os_path: String = file
	if file.begins_with("res://"):
		os_path = ProjectSettings.globalize_path(file)
	var bps: Array = []
	for l: Variant in lines:
		bps.append({"line": l})
	_queue.append({
		"id": mailbox_id,
		"command": "setBreakpoints",
		"args": {
			"source": {"path": os_path},
			"breakpoints": bps,
		},
		"file": file,
	})
	return true


func _queue_config_done() -> void:
	if _config_done_queued:
		return
	# Don't double-queue if one is already waiting or in flight.
	for item: Variant in _queue:
		if item.get("command", "") == "configurationDone":
			return
	if _in_flight.get("command", "") == "configurationDone":
		return
	_config_done_queued = true
	_queue.append({"id": "", "command": "configurationDone", "args": {}})


# ---------------------------------------------------------------------------
# Lifecycle (called by the core)
# ---------------------------------------------------------------------------

func on_game_started() -> void:
	_game_active = true
	_reconnect_at_ms = 0


func on_game_stopped() -> void:
	_game_active = false
	attached = false
	breaked = false
	last_stopped = {}
	_want_attached = false
	_queue.clear()
	_in_flight = {}
	_pending.clear()
	_tx_pending = PackedByteArray()
	_tx_item = {}
	_config_done_queued = false
	# A dead game has no live breakpoints; keeping the map would report a
	# stale breakpoint_count for the next (unattached) game session.
	breakpoints.clear()
	state_changed.emit()


func _ensure_connecting() -> void:
	if phase != Phase.DISCONNECTED:
		return
	if _game_active or _want_attached:
		phase = Phase.CONNECTING
		_rx = PackedByteArray()
		_tx_pending = PackedByteArray()
		_tx_item = {}
		_initialized_seen = false
		_config_done_queued = false
		var err: int = peer.connect_to_host("127.0.0.1", port)
		if err != OK:
			_connect_failed("connect_to_host: " + error_string(err))


func _connect_failed(reason: String) -> void:
	phase = Phase.DISCONNECTED
	peer = StreamPeerTCP.new()
	_tx_pending = PackedByteArray()
	_tx_item = {}
	_reconnect_at_ms = Time.get_ticks_msec() + 2000  # backoff
	_emit("debugger_dap", {"state": "disconnected", "reason": reason})


# ---------------------------------------------------------------------------
# Tick (every core poll, ~50 ms)
# ---------------------------------------------------------------------------

func tick() -> void:
	match phase:
		Phase.DISCONNECTED:
			# Idle until a game session is active or an attach was requested —
			# an idle connection serves no purpose (and a stray initialize
			# would trigger breakpoint sync for no reason).
			if (_game_active or _want_attached) \
					and Time.get_ticks_msec() >= _reconnect_at_ms:
				_diag_note("DISC->CONN")
				_ensure_connecting()
		Phase.CONNECTING:
			peer.poll()
			match peer.get_status():
				StreamPeerTCP.STATUS_CONNECTED:
					_diag_note("CONN->READY (st=%d avail=%d)" % [peer.get_status(), peer.get_available_bytes()])
					phase = Phase.READY
					_last_send_ms = Time.get_ticks_msec()
					_emit("debugger_dap", {"state": "connected", "port": port})
					_send({"id": "", "command": "initialize", "args": {
						"linesStartAt1": true,
						"columnsStartAt1": true,
						"supportsVariableType": true,
					}})
				StreamPeerTCP.STATUS_CONNECTING:
					pass
				_:
					_diag_note("CONN->FAIL st=%d" % peer.get_status())
					_connect_failed("connect failed: " + error_string(peer.get_status()))
					return
		Phase.READY:
			peer.poll()
			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				_diag_note("READY->LOST st=%d" % peer.get_status())
				_connect_failed("connection lost")
				return
			# Keepalive only when fully idle: a queued request goes out within
			# 50 ms anyway, and while one is in flight no request ARRIVES, so
			# the server's 5 s idle-timeout can't trigger.
			if _in_flight.is_empty() and _queue.is_empty() \
					and Time.get_ticks_msec() - _last_send_ms > KEEPALIVE_MS:
				_queue.append({"id": "", "command": "threads", "args": {}, "keepalive": true})
			_poll_rx()
			_flush_tx()
			_pump_queue()


# ---------------------------------------------------------------------------
# Wire protocol
# ---------------------------------------------------------------------------

func _send(item: Dictionary) -> void:
	_seq += 1
	item["seq"] = _seq  # bookkeeping: _on_response matches in-flight by this
	# Proper DAP request shape. The server reads params["arguments"] (C++
	# Dictionary::operator[] — a missing key logs a "Bug" error and yields an
	# EMPTY dict, which silently breaks setBreakpoints/evaluate/launch).
	var req: Dictionary = {
		"seq": _seq,
		"type": "request",
		"command": str(item.get("command", "")),
		"arguments": item.get("args", {}),
	}
	var payload: PackedByteArray = JSON.stringify(req).to_utf8_buffer()
	# Server parses the header with header.substr(16) — it must be exactly
	# "Content-Length: N" (single header, space after colon, no extras).
	var frame: PackedByteArray = ("Content-Length: %d\r\n\r\n" % payload.size()).to_utf8_buffer()
	frame.append_array(payload)
	_tx_item = item
	_tx_pending.append_array(frame)
	_flush_tx()


## Drain the TX buffer with the non-blocking put_partial_data(). A request is
## only marked in flight once its ENTIRE frame has been delivered (a partial
## tail, if any, is retried on the next tick).
func _flush_tx() -> void:
	if _tx_pending.is_empty():
		return
	var res: Array = peer.put_partial_data(_tx_pending)
	var err: int = int(res[0])
	var sent: int = maxi(0, int(res[1]))
	if sent > 0:
		_tx_pending = _tx_pending.slice(sent)
	if sent <= 0 and err != OK:
		_diag_note("TX-FAIL err=%d" % err)
		_connect_failed("put_partial_data: " + error_string(err))
		return
	if _tx_pending.is_empty() and not _tx_item.is_empty():
		var item: Dictionary = _tx_item
		_tx_item = {}
		_diag_sends += 1
		_diag_note("SEND #%d %s (seq=%d)" % [_diag_sends, str(item.get("command", "?")), _seq])
		_pending[_seq] = str(item.get("id", ""))
		_last_item = item
		_in_flight = item
		_last_send_ms = Time.get_ticks_msec()


func _pump_queue() -> void:
	if _in_flight.is_empty() and not _queue.is_empty():
		_send(_queue.pop_front())


func _poll_rx() -> void:
	# get_partial_data = the non-blocking read (returns whatever is available,
	# 0 bytes if nothing). Plain get_data(n) would BLOCK until n bytes arrive —
	# a deadlock in this same-process design (see _tx_pending comment).
	while peer.get_available_bytes() > 0:
		var res: Array = peer.get_partial_data(65536)
		if int(res[0]) != OK:
			_connect_failed("get_partial_data: " + str(res[0]))
			return
		var chunk: PackedByteArray = res[1]
		if chunk.is_empty():
			break
		_rx.append_array(chunk)
		_diag_rx_bytes += chunk.size()
	_parse_frames()


## Index of the first "\r\n\r\n" at or after `from`, or -1.
## (4.8-dev PackedByteArray.find() takes a single byte, not a sub-array.)
func _find_header_end(data: PackedByteArray, from: int) -> int:
	var i: int = from
	while i < data.size():
		i = data.find(13, i)  # '\r'
		if i < 0:
			return -1
		if i + 3 < data.size() and data[i + 1] == 10 and data[i + 2] == 13 and data[i + 3] == 10:
			return i
		i += 1
	return -1


func _parse_frames() -> void:
	while true:
		var idx: int = _find_header_end(_rx, 0)
		if idx < 0:
			if _rx.size() > _MAX_RX:  # drop unparseable garbage
				_rx = PackedByteArray()
			return
		var header: String = _rx.slice(0, idx).get_string_from_ascii()
		var length: int = 0
		for part: String in header.split("\r\n"):
			if part.begins_with("Content-Length:"):
				length = int(part.trim_prefix("Content-Length:").strip_edges())
		var total: int = idx + 4 + length
		if _rx.size() < total:
			return
		var body: String = _rx.slice(idx + 4, total).get_string_from_utf8()
		_rx = _rx.slice(total)
		var msg: Variant = JSON.parse_string(body)
		_diag_frames += 1
		if msg is Dictionary:
			_diag_last_msg = str(msg.get("type", "")) + "/" + str(msg.get("command", msg.get("event", "")))
			_handle_message(msg)


func _handle_message(msg: Dictionary) -> void:
	match str(msg.get("type", "")):
		"response":
			_on_response(msg)
		"event":
			_on_event(str(msg.get("event", "")), msg.get("body", {}))
		# "request" (server -> client) is unused by this adapter.


func _on_response(msg: Dictionary) -> void:
	var seq: int = int(msg.get("request_seq", -1))
	if not _pending.has(seq):
		return  # stale/duplicate
	var id: String = str(_pending.get(seq, ""))
	_pending.erase(seq)
	# Defensive: an empty _in_flight (bookkeeping out of sync) must never wedge
	# the pump — only a genuinely different in-flight seq is out-of-order.
	if _in_flight.is_empty() or int(_in_flight.get("seq", -1)) == seq:
		_in_flight = {}
	else:
		return  # out-of-order (should not happen: serial queue)

	var success: bool = bool(msg.get("success", false))
	var body: Variant = msg.get("body", {})
	var item: Dictionary = _last_item  # the request this response belongs to
	var command: String = str(item.get("command", ""))

	match command:
		"attach":
			if success:
				attached = true
				_write_response(id, _ok_body(body))
				var post: Variant = item.get("post", {})
				if post is Dictionary and not post.is_empty():
					_queue.append(post)
				_queue_config_done()
			else:
				_want_attached = false
				if id != "":
					_write_response(id, _dap_error(msg, command))
			state_changed.emit()
			return
		"launch":
			attached = true  # the server starts the game on configurationDone
			if id != "":
				_write_response(id, _ok_body(body))
			state_changed.emit()
			return
		"configurationDone":
			_config_done_queued = false
			if id != "":
				_write_response(id, _ok_body(body))
			return
		"disconnect":
			attached = false
			_want_attached = false
			if id != "":
				_write_response(id, _ok_body(body))
			state_changed.emit()
			return
		"setBreakpoints":
			if success:
				_apply_set_breakpoints(str(item.get("file", "")), body)
			if id != "":
				_write_response(id, _ok_body(body) if success else _dap_error(msg, command))
			return
		_:
			if id != "":
				_write_response(id, _ok_body(body) if success else _dap_error(msg, command))


## Last item handed to _send (responses are matched serially, so this is
## always the request the current response belongs to).
var _last_item: Dictionary = {}


func _apply_set_breakpoints(file: String, body: Variant) -> void:
	if file == "":
		return
	if body is Dictionary:
		var out: Dictionary = {}
		for bp: Variant in body.get("breakpoints", []):
			if bp is Dictionary:
				out[int(bp.get("line", 0))] = bool(bp.get("verified", true))
		if out.is_empty():
			breakpoints.erase(file)
		else:
			breakpoints[file] = out


func _ok_body(body: Variant) -> Dictionary:
	var result: Dictionary = {"ok": true}
	if body is Dictionary:
		result.merge(body, true)
	elif body != null and body != {}:
		result["body"] = body
	return result


## DAP error response shape: {success:false, message:"<error_id>",
## body:{error:{id, format, variables}}}.
func _dap_error(msg: Dictionary, command: String) -> Dictionary:
	var message: String = str(msg.get("message", ""))
	var body: Variant = msg.get("body", {})
	if body is Dictionary:
		var err: Variant = body.get("error", {})
		if err is Dictionary:
			if str(err.get("format", "")) != "":
				message = (message + ": " if message != "" else "") + str(err.get("format"))
			var variables: Variant = err.get("variables", {})
			if variables is Dictionary:
				for key: Variant in variables:
					message += " %s=%s" % [str(key), str(variables[key])]
	if message == "":
		message = "DAP request failed"
	return {"ok": false, "error": {"code": -32000, "command": command, "message": message}}


func _write_response(id: String, response: Dictionary) -> void:
	if _bridge != null:
		_bridge._write_response(id, response)


# ---------------------------------------------------------------------------
# Events (server -> client)
# ---------------------------------------------------------------------------

func _on_event(event: String, body: Variant) -> void:
	if not (body is Dictionary):
		body = {}
	match event:
		"initialized":
			_initialized_seen = true
			# Launch flow: configurationDone must follow the queued launch.
			if _want_attached and not _config_done_queued:
				_queue_config_done()
		"process":
			pass  # informational (launch/attach started server-side)
		"stopped":
			breaked = true
			var data: Dictionary = {
				"reason": str(body.get("reason", "")),
				"thread_id": int(body.get("threadId", 1)),
			}
			if body.has("hitBreakpointIds"):
				data["hit_breakpoint_ids"] = body.get("hitBreakpointIds")
			if body.has("text"):
				data["text"] = str(body.get("text"))
			# Persist the pause detail so state.json (and thus a failed game
			# command's inline report) can show WHY the game froze.
			last_stopped = {
				"reason": data.get("reason", ""),
				"text": data.get("text", ""),
				"at_ms": Time.get_ticks_msec(),
			}
			_emit("debugger_stopped", data)
		"continued":
			breaked = false
			last_stopped = {}
			_emit("debugger_continued", {"thread_id": int(body.get("threadId", 1))})
		"output":
			var line: String = str(body.get("output", "")).strip_edges()
			if line != "":
				output_lines.append(line)
				if output_lines.size() > OUTPUT_MAX:
					output_lines = output_lines.slice(output_lines.size() - OUTPUT_MAX)
				_emit("debugger_output", {
					"category": str(body.get("category", "stdout")), "line": line,
				})
		"terminated":
			attached = false
			breaked = false
			last_stopped = {}
			_want_attached = false
			_emit("debugger_terminated", {})
		"exited":
			_emit("debugger_exited", {"exit_code": int(body.get("exitCode", 0))})
		"breakpoint":
			var bp: Variant = body.get("breakpoint", {})
			var source: Variant = bp.get("source", {}) if bp is Dictionary else {}
			var path: String = str(source.get("path", "")) if source is Dictionary else ""
			path = _norm_path(path)
			var line: int = int(bp.get("line", 0)) if bp is Dictionary else 0
			var reason: String = str(body.get("reason", ""))
			if reason == "new" and path != "":
				breakpoints.get_or_add(path, {})[line] = true
			elif path != "":
				if breakpoints.has(path):
					breakpoints[path].erase(line)
					if breakpoints[path].is_empty():
						breakpoints.erase(path)
			_emit("debugger_breakpoint", {"reason": reason, "path": path, "line": line})
		"godot/custom_data":
			_emit("debugger_custom", {
				"message": str(body.get("message", "")),
				"data": body.get("data", []),
			})
		_:
			# Unknown events pass through (forward-compatible).
			_emit("debugger_event_" + event, body)
	state_changed.emit()


func _emit(event: String, data: Dictionary) -> void:
	if _bridge != null:
		_bridge._emit_event(event, data)


# ---------------------------------------------------------------------------
# Introspection (for query.debugger.state)
# ---------------------------------------------------------------------------

func get_state() -> Dictionary:
	return {
		"connected": phase == Phase.READY,
		"port": port,
		"attached": attached,
		"breaked": breaked,
		"last_stopped": last_stopped,
		"game_active": _game_active,
		"breakpoint_count": _count_breakpoints(),
		"pending_requests": _pending.size(),
		"queued_requests": _queue.size(),
		"output_lines_buffered": output_lines.size(),
		"diag_rx_bytes": _diag_rx_bytes,
		"diag_frames": _diag_frames,
		"diag_last_msg": _diag_last_msg,
		"diag_sends": _diag_sends,
		"diag_log": _diag_log,
	}


func _count_breakpoints() -> int:
	var n: int = 0
	for file: Variant in breakpoints:
		n += (breakpoints[file] as Dictionary).size()
	return n


## Full breakpoint map: {file: {line: verified}}
func get_breakpoints() -> Dictionary:
	return breakpoints.duplicate(true)
