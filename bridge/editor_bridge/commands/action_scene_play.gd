@tool
extends RefCounted

## action.scene.play — start the game (separate OS process).
## Args: {"path": ""} (empty = main scene)
## (the game_started event is emitted by the core's state diff)

func execute(args: Dictionary, ctx) -> Dictionary:
	var ei = ctx.editor_interface
	if ei.is_playing_scene():
		return ctx.make_error(-32602, "Game already playing: " + ei.get_playing_scene())
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		ei.play_main_scene()
	else:
		ei.play_custom_scene(path)
	return {"ok": true, "playing": path if not path.is_empty() else "(main scene)"}
