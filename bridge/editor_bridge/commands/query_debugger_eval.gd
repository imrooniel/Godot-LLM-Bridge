@tool
extends RefCounted

## query.debugger.evaluate — evaluate an expression in the paused frame
## (DAP `evaluate`). Requires breaked.
## Args: {"expression": "player.hp", "frame": 0}   (frame defaults to the
## last frame used with `variables`)
## Async: the expression runs in the GAME process; the response arrives when
## the evaluation returns. NOTE: evaluations are volatile in the adapter —
## each expression is evaluated at most once per pause (re-send to re-eval).
## Returns body: {"result": "value string", "variablesReference": N}

func execute(args: Dictionary, ctx) -> Variant:
	var dap_or_err: Variant = ctx.require_dap_attached()
	if dap_or_err is Dictionary:
		return dap_or_err
	var dap = dap_or_err
	var expression: String = str(args.get("expression", ""))
	if expression.is_empty():
		return ctx.make_error(-32602, "expression required")
	var frame: int = int(args.get("frame", 0))
	dap.wake()
	if not dap.enqueue(ctx.current_request_id, "evaluate",
			{"expression": expression, "frameId": frame}):
		return ctx.make_error(-32000, "DAP not connected")
	return null  # async
