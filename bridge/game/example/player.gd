## M2 4-direction walker. CharacterBody2D root; polls held input (bridge OR
## keyboard), drives the state machine, and move_and_slide()s against tiles.
## See spec §Input model and §Files.
extends CharacterBody2D

enum Facing { NONE, UP, DOWN, LEFT, RIGHT }

const SPEED: float = 60.0

## `velocity` is the native CharacterBody2D property (already Vector2.ZERO) —
## not redeclared (a script var of the same name is a 4.x parse error).
var facing: Facing = Facing.DOWN
var is_moving: bool = false

@onready var _sprite: AnimatedSprite2D = $Sprite
@onready var _machine: Node = $StateMachine

func _physics_process(_delta: float) -> void:
	var v := _movement_vector()
	facing = _dominant_facing(v)
	is_moving = v != Vector2.ZERO
	var target: String = "walk" if is_moving else "idle"
	_machine.change_state(target, facing)
	velocity = v * SPEED
	move_and_slide()
	_sprite.flip_h = (facing == Facing.LEFT)

## Per-action strength = bridge-held OR real-keyboard. `get_action_strength` is
## only reachable this way because `push_input` (what `game hold` issues) never
## updates the polled Input singleton — the bridge keeps its own held set.
## See spec §Input model.
func _action(action: String) -> float:
	if DebugBridge.is_action_held(action):
		return 1.0
	return Input.get_action_strength(action)

func _movement_vector() -> Vector2:
	var up := _action("move_up")
	var down := _action("move_down")
	var left := _action("move_left")
	var right := _action("move_right")
	return Vector2(right - left, down - up)

## Dominant axis only (no diagonals); NONE when idle.
func _dominant_facing(v: Vector2) -> Facing:
	if v == Vector2.ZERO:
		return Facing.NONE
	if absf(v.x) >= absf(v.y):  # tie (diagonal) -> horizontal wins (deterministic; diagonals out of M2 scope)
		return Facing.RIGHT if v.x > 0 else Facing.LEFT
	return Facing.DOWN if v.y > 0 else Facing.UP
