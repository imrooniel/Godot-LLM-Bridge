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
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	if not dap.attached:
		return ctx.make_error(-32002, "Not attached (run `debugger attach` first)")
	var expression: String = str(args.get("expression", ""))
	if expression.is_empty():
		return ctx.make_error(-32602, "expression required")
	var frame: int = int(args.get("frame", 0))
	dap.wake()
	if not dap.enqueue(ctx.current_request_id, "evaluate",
			{"expression": expression, "frameId": frame}):
		return ctx.make_error(-32000, "DAP not connected")
	return null  # async
