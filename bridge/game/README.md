# bridge/game — hook-in guide + worked example

This folder is the canonical answer to "how do I wire my own game into the bridge?"

- `GUIDE.md` — the 5-step contract (autoload, input map, `is_action_held` OR-hook, state hub,
  transitions) with the generic pattern for each.
- `example/` — the **worked JRPG sample**: real copies of the dogfood game's hook files
  (`player.gd`, `npc.gd`, `game_runtime.gd`, `transition_zone.gd`). These are reference
  documentation, not compiled bridge code — they keep their original in-game `res://` paths.

The live versions of these files live in the game tree (`scripts/actors/`, `autoloads/`,
`scripts/tools/`); `example/` holds copies so the example travels with the bridge.
