@tool
extends RefCounted

## Non-blocking TCP client to the in-game DebugBridge (127.0.0.1:5555).
##
## The game runs as a separate OS process; this is the ONLY path from the
## editor to the live game. The game bridge is single-client, so at most
## one request is in flight.
##
## Usage from the core poll loop:
##   start_request(id, method, params, timeout) -> bool
##   tick() -> Array of {"id", "response"} or {"id", "error"} completions
##
## Loopback connects resolve (RST or accept) almost instantly, so no
## cross-frame waiting is needed to establish the connection.

const HOST := "127.0.0.1"
const PORT := 5555
const DEFAULT_TIMEOUT_S := 120.0
const CONNECT_WAIT_MS := 1000

var _peer: StreamPeerTCP = null
var _pending: Dictionary = {}  # id -> {"deadline_ms": int, "timeout_s": float, "buffer": String}


func is_reachable() -> bool:
	if _peer == null:
		return false
	_peer.poll()
	return _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func reset() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
	_peer = null


## Begin a request. Returns false if another request is in flight or the
## game bridge is unreachable (game not running / bridge not started).
func start_request(id: String, method: String, params: Dictionary, timeout_s: float = DEFAULT_TIMEOUT_S) -> bool:
	if not _pending.is_empty():
		return false
	if not _ensure_connected():
		return false
	var req: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
	var line: String = JSON.stringify(req, "", false) + "\n"
	var err: Error = _peer.put_data(line.to_utf8_buffer())
	if err != Error.OK:
		reset()
		return false
	_pending[id] = {
		"deadline_ms": Time.get_ticks_msec() + int(timeout_s * 1000.0),
		"timeout_s": timeout_s,
		"buffer": "",
	}
	return true


## Poll the peer and collect any completed requests. Call from the core
## poll loop (20 Hz).
func tick() -> Array:
	var completed: Array = []
	if _pending.is_empty():
		if _peer != null and not is_reachable():
			reset()
		return completed

	if not is_reachable():
		for id: String in _pending.keys():
			completed.append(_fail(id, "game bridge disconnected mid-request"))
		_pending.clear()
		reset()
		return completed

	_peer.poll()
	var available: int = _peer.get_available_bytes()
	if available > 0:
		var result: Array = _peer.get_partial_data(available)
		var text: String = result[1].get_string_from_utf8()
		for id: String in _pending.keys():
			_pending[id].buffer += text

	for id: String in _pending.keys():
		var p: Dictionary = _pending[id]
		# Consume complete lines; keep the one whose "id" matches our request.
		# Lines without a matching id (e.g. JSON-RPC notifications/acks, or stray
		# log notifications pushed by the game) are skipped, not treated as the
		# response. This lets execute_lua send an early ack and still return the
		# real result.
		var matched := false
		while not matched and p.buffer.length() > 0:
			var nl: int = p.buffer.find("\n")
			if nl < 0:
				break
			var line: String = p.buffer.substr(0, nl).strip_edges()
			p.buffer = p.buffer.substr(nl + 1)
			if line.is_empty():
				continue
			var parsed: Variant = JSON.parse_string(line)
			if not (parsed is Dictionary):
				completed.append(_fail(id, "game bridge returned invalid JSON"))
				_pending.erase(id)
				matched = true
				break
			var line_id: Variant = parsed.get("id", null)
			# Match by id. Our request id is the numeric 1 (see start_request),
			# but the pending key `id` is a unique String; compare against the
			# JSON-RPC id we sent (always 1) — so accept any line with an "id".
			if line_id != null:
				completed.append({"id": id, "response": parsed})
				_pending.erase(id)
				matched = true
		if matched:
			continue
		if Time.get_ticks_msec() > p.deadline_ms:
			completed.append(_fail(id, "game bridge request timed out after %.0fs" % p.timeout_s))
			_pending.erase(id)
			reset()  # a timed-out request desyncs the stream — reconnect

	return completed


func _fail(id: String, message: String) -> Dictionary:
	return {"id": id, "error": message}


func _ensure_connected() -> bool:
	if is_reachable():
		return true
	reset()
	_peer = StreamPeerTCP.new()
	var err: Error = _peer.connect_to_host(HOST, PORT)
	var waited_ms := 0
	while err == Error.OK and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and waited_ms < CONNECT_WAIT_MS:
		_peer.poll()
		OS.delay_msec(10)
		waited_ms += 1
	if err != Error.OK or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		reset()
		return false
	_peer.set_no_delay(true)
	return true
