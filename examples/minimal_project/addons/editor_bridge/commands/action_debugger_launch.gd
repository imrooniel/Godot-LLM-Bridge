@tool
extends RefCounted

## action.debugger.launch — start a game THROUGH DAP (EditorRunBar).
## Args: {"scene": "res://..."|"" (main scene), "play_args": ["a","b"],
##        "no_debug": false}
## Async: responds when the launch handshake completes (game starting).

func execute(args: Dictionary, ctx) -> Variant:
	var dap = ctx.dap
	if dap == null:
		return ctx.make_error(-32603, "DAP session not initialized (4.8+ engine required)")
	if dap.attached:
		return ctx.make_error(-32002, "Already attached — stop the game first (`action scene-stop`)")
	var scene: String = str(args.get("scene", ""))
	var play_args: Array = args.get("play_args", [])
	var no_debug: bool = bool(args.get("no_debug", false))
	dap.wake()
	if not dap.launch(ctx.current_request_id, scene, play_args, no_debug):
		return ctx.make_error(-32000, "DAP not connected (port %d)" % dap.port)
	return null  # async
