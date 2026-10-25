@tool
extends RefCounted

## action.debugger.attach — attach the DAP session to the game the editor is
## currently running (async: responds when the handshake completes).
## REVIEW (C7): an early attach (right after scene-play, while the DAP client is
## still DISCONNECTED) used to fail with the misleading "DAP unreachable". Now,
## if a game is active, we force a connect and retry IMMEDIATELY (no await).

func execute(_args: Dictionary, ctx) -> Variant:
	var dap_or_err: Variant = ctx.require_dap()
	if dap_or_err is Dictionary:
		return dap_or_err
	var dap = dap_or_err
	if dap.attached:
		return {"ok": true, "attached": true, "note": "already attached"}
	var id: String = str(ctx.current_request_id)
	dap.wake()
	if dap.attach(id):
		return null  # async: the attach mailbox response answers the CLI
	# attach() returned false because the client is DISCONNECTED (game_started ->
	# DISC->CONN race). If a game is active, force a connect and retry IMMEDIATELY:
	# _ensure_connecting() sets phase=CONNECTING synchronously and _connectable()
	# accepts CONNECTING, so the retry succeeds now. NO await (see docstring).
	var game_running: bool = bool(ctx.state.get("game", {}).get("running", false))
	if game_running:
		dap._ensure_connecting()
		if dap.attach(id):
			return null
	return ctx.make_error(-32000,
		"DAP client not connected yet (game may still be starting; the debug adapter "
		+ "runs for the whole editor session). Retry in a moment, or check `debugger state`.")
