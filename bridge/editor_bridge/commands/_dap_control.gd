@tool
extends RefCounted

## Shared table-driven implementation for the 5 DAP control commands
## (pause / continue / step_over / step_into / step_out). See F14-4.
##
## Each command file is a thin wrapper that delegates here with its verb.
## The table maps verb -> (DAP command string, payload). `step_out` is the
## odd one out: the DAP adapter has no stepOut request, so it goes through
## the `godot/put_msg` pass-through with a different payload — preserved here.
##
## Guard order (identical to the original per-command prologue):
##   require_dap_attached()  ->  dap.wake()  ->  dap.enqueue(...)  ->  null (async)

const DAP_CONTROL := {
	"pause": {"cmd": "pause", "args": {"threadId": 1}},
	"continue": {"cmd": "continue", "args": {"threadId": 1}},
	"step_over": {"cmd": "next", "args": {"threadId": 1}},
	"step_into": {"cmd": "stepIn", "args": {"threadId": 1}},
	"step_out": {"cmd": "godot/put_msg", "args": {"message": "out", "data": []}},
}


## Runs the control command for `verb`. Returns the error Dictionary on guard
## failure, or null (async — the DAP response is written later) on success.
static func run(verb: String, ctx) -> Variant:
	var dap_or_err: Variant = ctx.require_dap_attached()
	if dap_or_err is Dictionary:
		return dap_or_err
	var entry: Dictionary = DAP_CONTROL.get(verb, {})
	if entry.is_empty():
		return ctx.make_error(-32602, "Unknown DAP control command: %s" % verb)
	var dap = dap_or_err
	dap.wake()
	if not dap.enqueue(ctx.current_request_id, entry.cmd, entry.args):
		return ctx.make_error(-32000, "DAP not connected")
	return null  # async
