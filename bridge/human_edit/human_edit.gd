@tool
extends EditorPlugin

## Captures HUMAN edits to the editor's edited scene as content deltas (spec §5, C4).
## Structural edits (node add/remove/rename) are SIGNAL-DRIVEN off the editor
## SceneTree, filtered to the edited scene; VALUE edits (no signal exists for
## them in the editor — see _on_poll) are caught by a low-frequency POLL that
## diffs the edited scene each tick. Only the edited scene's nodes are
## diffed/recorded, so the editor's own UI churn never reaches the buffer.
## Deltas are buffered and served by the EditorBridge via query.human.deltas
## (a pull). A push/subscribe path is intentionally NOT implemented: the
## bridge's event emitter is private (_emit_event) and the subscribe glue is
## out of scope for this stage (spec §8 stage 6) — pull is the reliable channel.
##
## Deliberately a SEPARATE small plugin (not editor_bridge.gd): it owns the
## edited-scene tree + the delta buffer; the EditorBridge command only reads it.

const MAX_BUFFER := 500
## The pure snapshot/diff/coalesce engine (Task 7). Preloaded (a stable
## res:// RefCounted, resolved at parse time) and instantiated ONCE in
## _enter_tree so the 5 Hz poll reuses it instead of re-allocating per node.
const DiffScript := preload("res://bridge/human_edit/human_edit_diff.gd")

var _buffer: Array = []            # list of {ts, turn_id, op, path, prop?, from?, to?}
var _last_snapshots: Dictionary = {}  # node_path -> snapshot dict
var _poll_timer: Timer
var _diff                          # one DiffScript instance, reused by the poll
## The SceneTree (NOT its Window root): tree_changed/node_added/node_removed/
## node_renamed are SCENE-TREE signals, not Window/Node signals. The plan's
## draft connected to get_tree().root (the Window), which has none of these
## signals, so every connection silently failed and no deltas were ever
## produced (verified live: "Attempt to connect nonexistent signal").
var _tree: SceneTree
var _scene_root: Node = null
var _turn_seq := 0

func _enter_tree() -> void:
	_tree = get_tree()
	_diff = DiffScript.new()
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 0.2  # 5 Hz value poll (diffs the edited scene each tick)
	_poll_timer.timeout.connect(_on_poll)
	add_child(_poll_timer)
	_poll_timer.start()
	_tree.connect("tree_changed", _on_tree_changed)
	_tree.connect("node_added", _on_node_added)
	_tree.connect("node_removed", _on_node_removed)
	_tree.connect("node_renamed", _on_node_renamed)
	_track_scene_root()

func _exit_tree() -> void:
	if is_instance_valid(_poll_timer):
		_poll_timer.timeout.disconnect(_on_poll)
	_poll_timer.queue_free()
	_poll_timer = null
	if _tree != null:
		if _tree.tree_changed.is_connected(_on_tree_changed):
			_tree.tree_changed.disconnect(_on_tree_changed)
		if _tree.node_added.is_connected(_on_node_added):
			_tree.node_added.disconnect(_on_node_added)
		if _tree.node_removed.is_connected(_on_node_removed):
			_tree.node_removed.disconnect(_on_node_removed)
		if _tree.node_renamed.is_connected(_on_node_renamed):
			_tree.node_renamed.disconnect(_on_node_renamed)
	_tree = null

## The edited scene root, or null if the editor singleton is not ready.
## (In the editor the `EditorInterface` identifier auto-resolves to the
## singleton; guard against the very-early case where it is not an object.)
func _current_edited_root() -> Node:
	if typeof(EditorInterface) != TYPE_OBJECT:
		return null
	return EditorInterface.get_edited_scene_root()

## The edited scene root changes when the human opens a different scene.
## Called at plugin startup AND polled each tick (the scene root can change at
## any time when the human switches scenes). We re-snapshot only when the root
## actually changed so we don't churn the baseline on every tick.
func _track_scene_root() -> void:
	var new_root: Node = _current_edited_root()
	if new_root != _scene_root:
		_scene_root = new_root
		_last_snapshots.clear()  # fresh baseline for the new scene
		if _scene_root:
			_snapshot_all()

## Called every poll tick to pick up a scene switch that happened between
## ticks (the scene root is not signalled by the SceneTree; EditorInterface
## is the source of truth). Cheap: only acts when the identity changed.
func _maybe_track_scene_root() -> void:
	if _scene_root == null:
		_track_scene_root()
		return
	if _current_edited_root() != _scene_root:
		_track_scene_root()

func _snapshot_all() -> void:
	_last_snapshots.clear()
	if _scene_root == null:
		return
	for n in _scene_root.find_children("*", "*", true, false):
		_last_snapshots[n.get_path()] = _diff.snapshot_node(_node_map(n))

func _node_map(n: Node) -> Dictionary:
	var d := {"name": n.name, "class": n.get_class()}
	for p in _props_of(n):
		d[p] = n.get(p)
	# tile/shape hashes (spec §5.2)
	if n is TileMapLayer:
		d["__cell_hash"] = _cell_hash(n)
	if n is CollisionShape2D and n.shape:
		d["__shape_hash"] = _shape_hash(n.shape)
	return d

func _props_of(n: Node) -> Array:
	var base := ["position", "rotation", "rotation_degrees", "scale", "visible", "z_index"]
	var cls := n.get_class()
	var extra: Array = []
	if cls == "AnimatedSprite2D":
		extra = ["animation"]
	elif cls == "Sprite2D":
		extra = ["flip_h", "flip_v"]
	return base + extra

func _snapshot_node(n: Node) -> Dictionary:
	return _diff.snapshot_node(_node_map(n))

func _cell_hash(t: TileMapLayer) -> String:
	# get_cell_source_id is a TileMapLayer method (4.8) — there is NO
	# TileData.get_source_id(), so reading it off the TileData returned by
	# get_cell_tile_data() was a nonexistent-function call (verified: spammed
	# the editor log every poll). Use the layer method per cell.
	var cells: Array = []
	for c in t.get_used_cells():
		cells.append([c.x, c.y, t.get_cell_source_id(c)])
	return _diff.hash_cells(cells)

func _shape_hash(s: Shape2D) -> String:
	# Hash the shape's defining fields directly (no per-tick deep-duplicate of
	# the Resource — that was the most expensive op in the old poll).
	var h: Array = [s.get_class()]
	if s is CircleShape2D:
		h.append((s as CircleShape2D).radius)
	elif s is RectangleShape2D:
		h.append((s as RectangleShape2D).size)
	elif s is CapsuleShape2D:
		h.append([(s as CapsuleShape2D).radius, (s as CapsuleShape2D).height])
	elif s is ConvexPolygonShape2D:
		h.append((s as ConvexPolygonShape2D).points.size())
	elif s is ConcavePolygonShape2D:
		h.append((s as ConcavePolygonShape2D).points.size())
	return _diff._hash_str(str(h))

# --- signals (structural) ---

## True when `n` is the edited scene root or a descendant of it. The SceneTree
## node_added/removed/renamed signals fire for EVERY node in the editor —
## including all of the editor's own UI (color pickers, tabs, progress bars,
## the script editor, …). We only want the EDITED SCENE, so we gate on scene
## membership; without this the buffer floods with editor-UI noise and the
## real human edits are drowned out (verified live: every captured buffer slot
## was an editor-UI delta, with none under the actually-edited scene).
func _in_edited_scene(n: Node) -> bool:
	if _scene_root == null or n == null:
		return false
	if n == _scene_root:
		return true
	var p: Node = n.get_parent()
	while p != null:
		if p == _scene_root:
			return true
		p = p.get_parent()
	return false


func _on_tree_changed() -> void:
	# tree_changed carries no node and fires for any property change in the
	# whole tree. It is kept connected only so a value edit inside the edited
	# scene is picked up on the next poll tick; the poll re-snapshots just the
	# edited scene, so editor-UI churn costs a (cheap) diff pass but emits
	# nothing.
	pass

func _on_node_added(n: Node) -> void:
	if not _in_edited_scene(n):
		return
	_emit({"op": "add", "path": n.get_path()})

func _on_node_removed(n: Node) -> void:
	# node_removed fires BEFORE the node leaves the tree; get_path() still
	# works. Filter to the edited scene.
	if not _in_edited_scene(n):
		return
	_emit({"op": "remove", "path": n.get_path()})

func _on_node_renamed(n: Node) -> void:
	if not _in_edited_scene(n):
		return
	_emit({"op": "rename", "path": n.get_path(), "to": n.name})

## Value poll. The plan called this a "gated" poll (diff only when a signal
## fired), but in the editor the edited scene lives in a SubViewport and
## SceneTree.tree_changed does NOT fire for a position/property set there
## (verified live: connected to tree_changed, moved the Player, the poll would
## have stayed idle). With no signal to gate on, a value edit would never be
## captured. So the poll diffs unconditionally each tick — the diff is cheap
## (only the edited scene's descendants) and only emits when a whitelisted
## property actually changed. Structural edits are still captured immediately
## by the node_added/removed/renamed signals.
func _on_poll() -> void:
	_maybe_track_scene_root()
	if _scene_root == null:
		return
	for n in _scene_root.find_children("*", "*", true, false):
		var snap: Dictionary = _diff.snapshot_node(_node_map(n))
		if _last_snapshots.has(n.get_path()):
			for op in _diff.diff_node(n.get_path(), _last_snapshots[n.get_path()], snap):
				_emit(op)
	_snapshot_all()  # refresh the baseline for the next diff

func _emit(delta: Dictionary) -> void:
	_turn_seq += 1
	delta["ts"] = Time.get_ticks_msec()
	delta["turn_id"] = _turn_seq
	_buffer.append(delta)
	if _buffer.size() > MAX_BUFFER:
		_buffer = _buffer.slice(_buffer.size() - MAX_BUFFER)

## Served by the EditorBridge command (query.human.deltas). `since_turn` is a
## turn_id (string on the wire); empty = all buffered.
func get_deltas(since_turn: String = "") -> Array:
	if since_turn.is_empty():
		return _buffer.duplicate()
	var since := int(since_turn)
	var out: Array = []
	for d in _buffer:
		if int(d.get("turn_id", 0)) > since:
			out.append(d)
	return out

func clear_buffer() -> void:
	_buffer.clear()
