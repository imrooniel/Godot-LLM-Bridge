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
##
## Response matching: each forwarded request gets a unique numeric jsonrpc
## id; incoming lines are only accepted as responses when their id matches a
## pending request. Server pushes (log_message notifications — same socket,
## no id) are skipped, never consumed as responses (dogfood BD-005: the old
## first-line-wins behavior returned stale/push frames as answers, skewing
## every subsequent game command by one).

const HOST := "127.0.0.1"
const PORT := 5555
const DEFAULT_TIMEOUT_S := 120.0
const CONNECT_WAIT_MS := 1000

## WRITE commands a coordinator would defer while the game is DAP-breaked (spec §4.3,
## BD-012 DAP-break variant). Reads are deliberately NOT gated — they answer from
## the game's already-frozen state and cannot wedge the single-client slot.
const _WRITE_COMMANDS := ["set", "call", "hold", "release", "change-scene", "start_scene",
	"key", "mouse", "signal", "time-scale", "quit", "rpc", "gd_eval", "eval"]

var _peer: StreamPeerTCP = null
var _game_breaked := false  # set by the editor via set_breaked(); polled before writes
var _pending: Dictionary = {}  # mail_id -> {"rpc_id": int, "deadline_ms": int, "timeout_s": float}
var _rx: String = ""            # shared inbound newline-delivered stream
var _next_rpc_id: int = 1
## Failure frames produced by start_request (stale-peer recovery) that the core
## must write out on its next tick — start_request is void-ish (bool) so it
## can't return them directly (dogfood BD-012).
var _stale_failures: Array = []


func is_reachable() -> bool:
	if _peer == null:
		return false
	_peer.poll()
	return _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func reset() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
	_peer = null
	_rx = ""


## The editor mirrors the DAP session's break state here. While true, WRITE
## commands are deferred (see start_request) rather than sent into a frozen game.
func set_breaked(b: bool) -> void:
	_game_breaked = b


## Begin a request. Returns false if another request is in flight or the
## game bridge is unreachable (game not running / bridge not started).
func start_request(id: String, method: String, params: Dictionary, timeout_s: float = DEFAULT_TIMEOUT_S) -> bool:
	# Coordinator defer (spec §4.3, BD-012): a game WRITE while the game is
	# DAP-breaked would hang to the proxy timeout (no frames advance while
	# breaked) and wedge the single-client slot. Fail fast with a legible,
	# structured deferred response instead of touching the peer.
	if _game_breaked and _WRITE_COMMANDS.has(method):
		_stale_failures = [{"id": id, "response": {
			"error": {
				"code": -32042,
				"message": "write deferred: game is paused at a breakpoint (DAP breaked=true)",
				"reason": "game_paused",
				"suggested": ["debugger continue", "retry this write after the game resumes"],
			},
		}}]
		return false
	if not _pending.is_empty():
		# A leftover _pending entry means a prior request was never completed
		# (its response was lost, e.g. mid scene-swap). If the peer is dead,
		# the request is unrecoverable — fail it and clear the slot so the
		# "one in flight" gate can't wedge permanently (dogfood BD-012). If the
		# peer is still alive, a response may still arrive on a later tick;
		# refuse rather than double-send (id matching would drop the reply).
		# We surface this via a completed frame the core writes immediately.
		if _peer == null or not is_reachable():
			_stale_failures = _fail_stale_pending()
		else:
			return false
	if not _ensure_connected():
		return false
	var rpc_id := _next_rpc_id
	_next_rpc_id += 1
	var req: Dictionary = {"jsonrpc": "2.0", "id": rpc_id, "method": method, "params": params}
	var line: String = JSON.stringify(req, "", false) + "\n"
	var err: Error = _peer.put_data(line.to_utf8_buffer())
	if err != Error.OK:
		reset()
		return false
	_pending[id] = {
		"rpc_id": rpc_id,
		"deadline_ms": Time.get_ticks_msec() + int(timeout_s * 1000.0),
		"timeout_s": timeout_s,
	}
	return true


## Poll the peer and collect any completed requests. Call from the core
## poll loop (20 Hz).
func tick() -> Array:
	var completed: Array = []
	# Surface any stale-peer failures stashed by start_request (the "one in
	# flight" gate recovered a lost request) so the core can write them out.
	if not _stale_failures.is_empty():
		completed.append_array(_stale_failures)
		_stale_failures = []
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
		if result[0] == Error.OK:
			_rx += (result[1] as PackedByteArray).get_string_from_utf8()

	# Dispatch every complete line: match responses by jsonrpc id, skip
	# notifications and anything unmatched (stale frames from earlier
	# requests are dropped rather than mis-answered).
	while true:
		var nl: int = _rx.find("\n")
		if nl < 0:
			break
		var line: String = _rx.substr(0, nl).strip_edges()
		_rx = _rx.substr(nl + 1)
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if not (parsed is Dictionary):
			continue  # malformed notification — ignore, stream stays usable
		if not parsed.has("id") or parsed.has("method"):
			continue  # server push (e.g. log_message) — not a response
		var mail_id: String = _find_pending_by_rpc(int(parsed["id"]))
		if mail_id == "":
			continue  # unmatched id — stale response, drop it
		completed.append({"id": mail_id, "response": parsed})
		_pending.erase(mail_id)

	for id: String in _pending.keys():
		var p: Dictionary = _pending[id]
		if Time.get_ticks_msec() > p.deadline_ms:
			completed.append(_fail(id, "game bridge request timed out after %.0fs" % p.timeout_s))
			_pending.erase(id)
			reset()  # a timed-out request desyncs the stream — reconnect

	return completed


func _find_pending_by_rpc(rpc_id: int) -> String:
	for id: String in _pending.keys():
		if int(_pending[id].rpc_id) == rpc_id:
			return id
	return ""


func _fail(id: String, message: String) -> Dictionary:
	return {"id": id, "error": message}


## Collect any _pending requests that can no longer be answered (peer dead)
## into completed failure frames, clearing the slot so start_request's
## "one in flight" gate cannot wedge permanently. Returns the completed
## frames (the caller appends them). (dogfood BD-012)
func _fail_stale_pending() -> Array:
	var out: Array = []
	if _pending.is_empty():
		return out
	if _peer == null or not is_reachable():
		for pid: String in _pending.keys():
			out.append(_fail(pid, "previous request lost (stale peer); retry the command"))
		_pending.clear()
		reset()
	return out


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
	_rx = ""  # drain-on-connect: drop any connect-time notification backlog
	return true
