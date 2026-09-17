@tool
extends RefCounted

## Quit the editor. Stop any running scene FIRST so the engine kills the game
## child cleanly (editor_run.cpp:231, SIGKILL) and the "Stop running project
## before exiting?" modal never appears (fixes C2/A6).
##
## REVIEW FIX: `execute()` must NOT `await`. The core calls it WITHOUT awaiting
## (`editor_bridge.gd` `_run_command`), so a body containing `await` returns a
## `GDScriptFunctionState` and the CLI gets a spurious -32603 (the quit would
## still fire, but the caller sees failure). Schedule the quit on a timer
## instead and return synchronously. The 0.5 s gap lets the stop propagate
## (the engine kills the game child) before the quit.
func execute(args: Dictionary, ctx) -> Dictionary:
	var ei = ctx.editor_interface
	var was_playing := bool(ei and ei.is_playing_scene())
	if was_playing:
		ei.stop_playing_scene()
		ctx.tree.create_timer(0.5).timeout.connect(func(): ctx.tree.quit())
	else:
		ctx.tree.quit()
	return {"ok": true, "message": "editor quitting", "stopped_scene": was_playing}
