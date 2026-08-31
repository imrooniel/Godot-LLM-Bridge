@tool
extends RefCounted

## action.debugger.attach — attach the DAP session to the game the editor is
## currently running (async: responds when the handshake completes).
## Errors: no active game session (DAP NOT_RUNNING), or DAP unreachable.

func execute(_args: Dictionary, ctx) -> Variant:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	if dap.attached:
		return {"ok": true, "attached": true, "note": "already attached"}
	dap.wake()
	if not dap.attach(ctx.current_request_id):
		return ctx.make_error(-32000,
			"DAP unreachable at 127.0.0.1:%d (engine must be 4.8+; is the debug adapter running?)" % dap.port)
	return null  # async
