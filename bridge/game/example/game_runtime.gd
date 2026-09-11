## GameRuntime — cross-scene game state + world/battle transitions.
##
## State is intentionally global here (Godot autoload pattern) but is mutated
## ONLY through the explicit API below, so runtime inspection (bridge eval /
## DAP) always observes a consistent shape. See docs/rpg-spec.md.
extends Node

const VILLAGE_SCENE := "res://scenes/world/village.tscn"
const FIELD_SCENE := "res://scenes/world/field.tscn"
const BATTLE_SCENE := "res://scenes/battle/battle.tscn"
const GAME_OVER_SCENE := "res://scenes/ui/game_over.tscn"

## Last-loaded world scene path (bridge-inspectable).
var current_map: String = ""
## Spawn point id inside current_map.
var spawn_point: String = "default"
## Story/quest/encounter flags, e.g. "elder_quest_taken", "enemy_field_1_defeated".
var flags: Dictionary = {}
## Party roster. Populated with defaults at boot; battle system mutates via API.
var party: Array[Dictionary] = []


func _ready() -> void:
	if party.is_empty():
		party = _default_party()


## Switch scenes and remember where the player should be placed.
func transition_to(scene_path: String, spawn := "default") -> void:
	current_map = scene_path
	spawn_point = spawn
	get_tree().change_scene_to_file.call_deferred(scene_path)


func set_flag(flag: String, value: Variant = true) -> void:
	flags[flag] = value


func get_flag(flag: String) -> Variant:
	return flags.get(flag)


func hero(index: int) -> Dictionary:
	return party[index]


func restore_party() -> void:
	for hero_data in party:
		hero_data.hp = hero_data.max_hp
		hero_data.alive = true


func _default_party() -> Array[Dictionary]:
	return [
		{"name": "Imru", "max_hp": 30, "hp": 30, "alive": true},
		{"name": "Sera", "max_hp": 24, "hp": 24, "alive": true},
		{"name": "Bolt", "max_hp": 20, "hp": 20, "alive": true},
	]
