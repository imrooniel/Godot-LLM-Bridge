extends Node
# EarlyLogCollector — registers the DebugLogCollector as an OS logger as early
# as possible (the FIRST autoload's _init()), so log/error entries that fire
# during the synchronous boot phase are captured: the 2nd–Nth autoloads'
# script compilation (SCRIPT ERRORs), the synchronous initial mod load, and
# early Lua module loading.
#
# Without this, the collector is only registered by DebugBridge (a later
# autoload), so everything that fires before that point is delivered to the
# console but never to the collector.
#
# This is a debug-build feature (no overhead in exports), mirroring DebugBridge.
#
# NOTE: errors that fire during ENGINE init (before ANY autoload's _init()) —
# e.g. C++ bind_method / get_id_path / load_image failures — are NOT captured
# here; they are only in the editor's process console (see the CLI `game logs`
# console/process fallback, which merges that source in).

func _init() -> void:
	if not OS.is_debug_build():
		return
	var collector: Logger = DebugLogCollector.new()
	DebugLogCollector.set_shared(collector)
	OS.add_logger(collector)
	# Clear at REGISTRATION time (moved here from DebugBridge._ready()): a
	# fresh process starts with an empty buffer, so this is a no-op there, but
	# it gives a clean slate for a persistent process. DebugBridge (a later
	# autoload) reuses this collector and does NOT clear it, so entries
	# captured from here onward are retained instead of being wiped.
	collector.clear_messages()
	# Truncate the per-pid log file (parity with the old session clear). Keyed
	# by pid so concurrent games don't truncate each other's file.
	var log_file: String = "/tmp/godot_output_%d.log" % OS.get_process_id()
	var file := FileAccess.open(log_file, FileAccess.WRITE)
	if file != null:
		file.close()
