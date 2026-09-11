extends SceneTree

func _init() -> void:
	var d = load("res://bridge/human_edit/human_edit_diff.gd").new()
	var fails := 0

	# snapshot: a node dict carries class + whitelisted value props.
	var snap: Dictionary = d.snapshot_node({"name": "Player", "class": "CharacterBody2D",
			"position": Vector2(10, 20), "rotation": 0.0, "scale": Vector2(1, 1), "visible": true})
	if snap.get("class") != "CharacterBody2D" or snap.get("position") != [10.0, 20.0] or snap.get("visible") != true:
		print("FAIL snapshot_node(): ", snap); fails += 1

	# diff: a changed position -> one "set" op with from/to.
	var old: Dictionary = d.snapshot_node({"name": "Player", "class": "CharacterBody2D",
			"position": Vector2(10, 20), "rotation": 0.0, "scale": Vector2(1, 1), "visible": true})
	var new: Dictionary = d.snapshot_node({"name": "Player", "class": "CharacterBody2D",
			"position": Vector2(14, 22), "rotation": 0.0, "scale": Vector2(1, 1), "visible": true})
	var ops: Array = d.diff_node("Player", old, new)
	if ops.size() != 1 or ops[0].get("op") != "set" or ops[0].get("prop") != "position" \
			or ops[0].get("from") != [10.0, 20.0] or ops[0].get("to") != [14.0, 22.0]:
		print("FAIL diff_node(set): ", ops); fails += 1

	# diff: unchanged -> no ops.
	var same: Array = d.diff_node("Player", old, d.snapshot_node({"name": "Player",
			"class": "CharacterBody2D", "position": Vector2(10, 20), "rotation": 0.0,
			"scale": Vector2(1, 1), "visible": true}))
	if same.size() != 0:
		print("FAIL diff_node(unchanged) should be empty: ", same); fails += 1

	# coalesce caps the batch and reports the dropped count via the Dictionary contract.
	var big: Array = []
	for i in 60: big.append({"op": "set", "path": "N%d" % i, "prop": "x", "from": 0, "to": i})
	var c: Dictionary = d.coalesce(big, 50)
	if c["ops"].size() != 50 or c["summary"] != 10:
		print("FAIL coalesce(): ops=", c["ops"].size(), " summary=", c["summary"]); fails += 1

	# hash_cells is deterministic (same cells -> same hash).
	var hc1: String = d.hash_cells([[0, 0, 0, 0, 0], [1, 2, 0, 0, 0]])
	var hc2: String = d.hash_cells([[0, 0, 0, 0, 0], [1, 2, 0, 0, 0]])
	if hc1 != hc2 or hc1.is_empty():
		print("FAIL hash_cells(): not deterministic: ", hc1, hc2); fails += 1

	if fails == 0:
		print("human_edit_test: PASS"); quit(0)
	else:
		print("human_edit_test: FAIL (%d)" % fails); quit(1)
