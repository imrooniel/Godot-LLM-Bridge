@tool
extends RefCounted

## action.fs.scan — trigger an editor filesystem scan.
##
## REQUIRED after creating scripts with `class_name` while the editor runs:
## global classes are registered ONLY by the filesystem scan
## (EditorFileSystem::_update_script_classes → global_script_class_cache.cfg,
## engine source editor_file_system.cpp:2145-2182). `scripts-reload`
## re-executes cached scripts but never touches the global class registry —
## scenes referencing a brand-new class fail to compile SILENTLY (the game
## process exits; `game ping` then shows game_running=false).
##
## The scan runs asynchronously across frames (it needs the main thread),
## so this returns immediately. Poll `query state` → `fs_scanning`, or use
## the CLI's `action fs-scan --wait`.

func execute(_args: Dictionary, ctx) -> Dictionary:
	var fs: EditorFileSystem = ctx.editor_interface.get_resource_filesystem()
	fs.scan()
	return {"ok": true, "scanning": fs.is_scanning()}
