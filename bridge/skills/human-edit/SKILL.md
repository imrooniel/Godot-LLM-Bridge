---
name: human-edit
description: Read what the HUMAN edited in the Godot editor since your last turn (content deltas: node add/remove/rename, property changes, scene saves). Use at the START of each turn so you work from a current picture, not a stale one. Trigger keywords: human-deltas, human edit, what did the human change, content deltas, turn start.
---

# Human-Edit Deltas

The human edits the Godot editor in their own turn (moves nodes, changes properties, paints tiles). Those edits are NOT in your context until you read them. Do this at the start of your turn:

## 1. Read the deltas
python3 bridge/cli/editor_bridge_cli.py query human-deltas

Returns (legibility contract):
    {"ok": true, "state": {…}, "result": {"deltas": [ … ]}}

Each delta:
    {"op": "set",    "path": "Player", "prop": "position", "from": [10,20], "to": [14,22]}
    {"op": "add",    "path": "Trees/Oak_2"}
    {"op": "remove", "path": "OldProp"}
    {"op": "scene",  "path": "res://scenes/world/my_scene.tscn", "event": "saved"}

- `set` = a property value changed (the human moved/resized/colored something).
- `add`/`remove` = a node was added/removed in the edited scene.
- `scene` = a scene was opened/saved (lifecycle).
- Tile/cell and shape changes are reported by hash; if you need the detail, read the node/prop directly with `game get` / `query scene-tree`.

## 2. Acknowledge, then act
Acknowledge in ONE line what the human did (e.g. "You moved Player to [14,22] and saved the scene — got it."), then proceed. Never act as if the world is unchanged.

## If there are no deltas
`{"deltas": []}` means the human made no captured edits since your last turn — proceed normally.

## Limits (v1)
- Captured deltas cover the EDITED scene's structure (add/remove/rename), scene lifecycle, and whitelisted property values (position/rotation/scale/visible/z_index). Very large tile repaints are reported by hash, not cell-by-cell.
- Deltas reflect the editor's in-memory edited scene; if the human edited but did not save, you still see it (that's the point) — but a reload/reopen may clear unsaved work.
