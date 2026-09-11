## Builds a map-transition zone: a PLAIN Area2D with a rectangular
## CollisionShape2D (covers the map edge so the player can't slip through a
## 1-tile gap). Shared by the village (east exit) and the field (west exit)
## builders — the node graph is identical, only the size differs.
##
## NOTE (M3, editor run-script context): the behavior script (transition_zone.gd)
## is deliberately NOT attached here. `action run-script` @tool-injects a copy of
## the builder, and calling set_script() with a script that references a
## game-process autoload (GameRuntime) throws in that injected context (silent
## data loss — the village builder lost its whole M3 section this way). Instead
## world.gd (attached to the scene root, NOT injected) attaches the script + sets
## target_scene/target_spawn in _ready(). See scripts/world/world.gd.
extends RefCounted

const SCRIPT := "res://scripts/world/transition_zone.gd"

## Returns a script-less Area2D named "Transition" with a CollisionShape2D child.
func build(zone_size: Vector2) -> Area2D:
	var zone := Area2D.new()
	zone.name = "Transition"

	var col := CollisionShape2D.new()
	col.name = "CollisionShape2D"
	var shape := RectangleShape2D.new()
	shape.size = zone_size
	col.shape = shape
	zone.add_child(col)
	_own_all(zone, zone)
	return zone

func _own_all(p: Node, r: Node) -> void:
	for c in p.get_children():
		(c as Node).owner = r
		_own_all(c, r)
