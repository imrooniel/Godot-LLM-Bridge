@tool
extends RefCounted

## logs.get — editor log lines.
## Args: {"from": 0, "max_lines": 500, "source": "auto"}
## Sources:
##   panel     — editor Output panel (editor output + GAME output; the
##               only source that captures the game process)
##   collector — editor-process Logger (prints + script/engine errors)
##   process   — captured editor stdout (.tmp/logs/editor-console.log),
##               the only record of pre-plugin-init startup output
##   auto      — panel if available, else collector

func execute(args: Dictionary, ctx) -> Dictionary:
	var from_index: int = maxi(0, int(args.get("from", 0)))
	var max_lines: int = maxi(1, int(args.get("max_lines", 500)))
	var source: String = str(args.get("source", "auto"))
	if source == "auto":
		source = "panel" if ctx.output_panel_text != null else "collector"

	var lines: Array
	match source:
		"panel":
			if ctx.output_panel_text == null or not (ctx.output_panel_text is RichTextLabel):
				return ctx.make_error(-32602, "Output panel not found yet (try source=collector)")
			# get_parsed_text(): the only reader that works on the threaded
			# EditorLog label (see editor_bridge.gd _panel_text).
			lines = ctx.output_panel_text.get_parsed_text().split("\n")
		"collector":
			lines = _collector_lines(ctx)
		"process":
			lines = _process_lines()
		_:
			return ctx.make_error(-32602, "Unknown source: " + source)

	var total: int = lines.size()
	var end: int = mini(from_index + max_lines, total)
	var slice: Array = lines.slice(from_index, end)
	return {
		"ok": true,
		"messages": slice,
		"total_lines": total,
		"from": from_index,
		"count": slice.size(),
		"source": source,
	}


func _collector_lines(ctx) -> Array:
	var raw = ctx.log_collector.get_messages()
	return raw


## Only the current launch section (the CLI writes a marker per launch).
func _process_lines() -> Array:
	var path := "res://.tmp/logs/editor-console.log"
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var all: Array = f.get_as_text().split("\n")
	f.close()
	var start := 0
	for i in range(all.size() - 1, -1, -1):
		if all[i].begins_with("=== EditorBridge launch"):
			start = i
			break
	return all.slice(start)
