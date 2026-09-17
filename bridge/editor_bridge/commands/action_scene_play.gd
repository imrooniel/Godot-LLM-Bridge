@tool
extends RefCounted

## action.scene.play — start the game (separate OS process).
## Args: {"path": ""} (empty = main scene)
## (the game_started event is emitted by the core's state diff)

func execute(args: Dictionary, ctx) -> Dictionary:
	var ei = ctx.editor_interface
	if ei and ei.is_playing_scene():
		return ctx.make_error(-32602, "Game already playing: " + ei.get_playing_scene())
	# C1: if a (possibly orphaned) game already owns the bridge port, starting
	# another game would make THIS game bind a different port while the proxy
	# may still be pointed at the old one. Surface it so the user can stop the
	# orphan (or the CLI pre-flight already warned).
	if ctx.game_proxy and ctx.game_proxy.is_reachable():
		return ctx.make_error(-32000,
			"A game is already reachable on the debug bridge (port %d) — likely an "
			+ "orphan from a previous session. `action scene-stop` it (if its editor "
			+ "is alive) or kill its pid, then retry scene-play."
			% ctx.game_proxy.discovered_port)
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		ei.play_main_scene()
	else:
		ei.play_custom_scene(path)
	return {"ok": true, "playing": path if not path.is_empty() else "(main scene)"}
