## M4 NPC interaction. Attached to an NPC (StaticBody2D) at RUNTIME by
## world.gd — NOT in the builder — because a `run-script` @tool-injected
## builder THROWS when assigning a script var that only exists on the
## serialized (non-injected) script (silent data loss; BD-018). The builder
## leaves the NPC as a plain StaticBody2D; world.gd `set_script()`s this and
## calls `setup()` (the same set_script-then-setup pattern as the transition
## zone).
##
## Model (per spec): an `Interact` Area2D detects the player within range;
## pressing `interact` (bridge-held OR keyboard) opens the DM4 balloon.
extends StaticBody2D

## Dialogue resource for this NPC, set by world.gd in setup().
var dialogue_resource: DialogueResource
## Character name shown in the balloon (DM4 falls back to this).
var dialogue_character: String = "Villager"

## Range (px) within which the player counts as "in front of" the NPC.
const INTERACT_RANGE: float = 44.0
## The balloon scene (M4 reskin).
const BALLOON_SCENE := "res://scenes/ui/dialogue_balloon.tscn"

var _player: CharacterBody2D
var _interact_area: Area2D
var _player_in_range: bool = false
var _interact_was_held: bool = false
## The DM4 autoload, resolved via the engine singleton (same as DM4's own
## example balloon) so the script type-checks under a bare headless
## `--check-only` where the autoload name isn't in scope.
var _dm: Node
## The DebugBridge autoload (engine singleton) — resolved this way so the script
## also type-checks under a bare headless `--check-only`.
var _bridge: Node

func _ready() -> void:
	_dm = Engine.get_singleton("DialogueManager")
	_bridge = Engine.get_singleton("DebugBridge")
	# Wire the interact area if one was serialized (it isn't in M4 — world.gd
	# creates it in setup() — but this keeps the serialized case working too).
	if get_node_or_null("Interact") is Area2D:
		_interact_area = get_node("Interact")
		_interact_area.body_entered.connect(_on_body_entered)
		_interact_area.body_exited.connect(_on_body_exited)
	# Keep the speaking character name in sync so the balloon labels it.
	if dialogue_character != "":
		_dm.register_state_context(&"npc", self)

## Called by world.gd AFTER set_script(). Builds the interact area if needed
## and (re)connects it. Idempotent.
func setup(res: DialogueResource = null, char: String = "") -> void:
	if res != null:
		dialogue_resource = res
	if char != "":
		dialogue_character = char
	_create_interact_area()
	# Re-read the current overlap (the area was just added and may already
	# overlap the player on load).
	_player = get_tree().get_first_node_in_group("player")
	if _player != null and global_position.distance_to(_player.global_position) <= INTERACT_RANGE:
		_player_in_range = true

func _create_interact_area() -> void:
	if _interact_area != null:
		return
	_interact_area = Area2D.new()
	_interact_area.name = "Interact"
	# Collision mask 1 = the tile collision layer; we test only the player, so
	# mask the player's body. Player is a CharacterBody2D (collision layer 1).
	_interact_area.collision_layer = 0
	_interact_area.collision_mask = 1
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = INTERACT_RANGE
	shape.shape = circle
	shape.position = Vector2(0, -8)  # bias toward the player's feet/center
	_interact_area.add_child(shape)
	add_child(_interact_area)
	_interact_area.body_entered.connect(_on_body_entered)
	_interact_area.body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node2D) -> void:
	if _is_player(body):
		_player = body
		_player_in_range = true

func _on_body_exited(body: Node2D) -> void:
	if _is_player(body) and body == _player:
		_player_in_range = false
		_player = null

func _is_player(body: Node) -> bool:
	return body is CharacterBody2D and body.is_in_group("player")

func _physics_process(_delta: float) -> void:
	# interact = bridge-held OR real-keyboard (the bridge pushes real key
	# events AND keeps its own held set; see player.gd _action). Keyboard
	# uses is_action_just_pressed (edge-triggered); the bridge's held set is
	# debounced so it doesn't re-open the balloon every physics tick while
	# held. Only react when the player is in range and no balloon is up.
	if _player_in_range and _no_dialogue_up() and _interact_pressed():
		_open_dialogue()

func _interact_pressed() -> bool:
	if Input.is_action_just_pressed("interact"):
		return true
	if _bridge.is_action_held("interact") and not _interact_was_held:
		_interact_was_held = true
		return true
	if not _bridge.is_action_held("interact"):
		_interact_was_held = false
	return false

func _no_dialogue_up() -> bool:
	# Don't re-open while a balloon is showing (the balloon blocks input, but
	# guard against the physics tick racing the balloon's own input handling).
	return not get_tree().root.has_node("DialogueBalloon")

func _open_dialogue() -> void:
	if dialogue_resource == null:
		return
	_dm.show_dialogue_balloon_scene(BALLOON_SCENE, dialogue_resource)
