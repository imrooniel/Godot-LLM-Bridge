# Agent Skill: Drive

Drive a **running** Godot 4 game in a **closed feedback loop**: inject held input → sample
per-frame telemetry → assert an invariant → adjust input → repeat. All commands go through
`scripts/editor_bridge_cli.py` under the `game` tree. Use this when the thing you care about
is a *time series* (position, rotation, gait, physics state) — a one-shot `game get` cannot
show motion.

> **When to use:** you need to *drive* the game (make something move) and *observe* it over
> time. Trigger keywords: drive loop, held input, hold key, release key, `game hold`,
> `game release`, `held-keys`, telemetry, `game watch`, `game sample`, `game get-many`,
> per-frame sample, invariant, close-the-loop, "drive the game", "make the player move".

## Pre-flight Checklist (DO THIS FIRST)

```bash
python3 scripts/editor_bridge_cli.py ping            # editor alive?
python3 scripts/editor_bridge_cli.py game ping       # game running + bridge reachable?
```
If `game ping` is not `game_running: true`, start the game (`action scene-play`) and wait for
the bridge (`game ping` → `"game_bridge": true`) before driving.

## The single-client rule (CRITICAL — read this)

The game bridge is **single-client and serializes one request at a time.** Two consequences:

1. **Space out your `game` calls.** Fire each command, **read its output, then send the next.**
   Do NOT fire a rapid burst of `game get` / `game hold` in one bash block — a quick sequence
   can read the *previous* pending response, and a mid-request bridge drop shows
   `game bridge disconnected mid-request`. Insert a `sleep 2` (or longer) between each `game`
   call, or run them as separate tool calls.
2. **Idempotent reads auto-retry; mutations don't.** `game get`, `get-many`, `watch`,
   `sample`, `held-keys`, `screenshot`, etc. are retried up to 3× on a transient drop.
   `hold`/`release`/`set`/`call` are NOT retried (a blind re-send could double-apply) — after a
   mutation, re-read state to confirm it applied. Use `--no-retry` to disable read retry.

## Held input

`game key` pushes an event that fires `_input` callbacks but does **not** update
`Input.is_key_pressed()` / `Input.get_vector()` polling. A polling controller (e.g. one that
reads `Input.get_vector`) will **not** see `game key`. **Use `game hold` / `game release`** —
they update the bridge's held set that the controller polls (and still push the event).

```bash
python3 scripts/editor_bridge_cli.py game hold W        # press AND hold (marks move_forward held)
python3 scripts/editor_bridge_cli.py game held-keys     # confirm W / move_forward is held
# ... let it run, sample ...
python3 scripts/editor_bridge_cli.py game release W     # ALWAYS release when done
```

## Telemetry — observe motion

`game watch` starts a per-frame sampler (frame-counter gated, fps-adaptive). `game sample`
returns the capped ring buffer. `game telemetry-stop` stops and discards it.

```bash
# Start: watch Main/Player's global_position and rotation.y at ~30 Hz
python3 scripts/editor_bridge_cli.py game watch --nodes Main/Player \
    --props '["global_position","rotation.y"]' --hz 30
sleep 2
# Read the last 3 samples (should show position changing while a key is held)
python3 scripts/editor_bridge_cli.py game sample --limit 3
# Stop when done
python3 scripts/editor_bridge_cli.py game telemetry-stop
```

Props are root-relative node paths + property names. Dotted sub-props work
(`rotation.y`, `global_transform.origin.x`). The buffer is capped (≈600 samples) — sample
before it fills and rolls over, or use `--limit`.

## Batch reads

Read many (node, prop) pairs in **one** round-trip (each `game get` is a full round-trip):

```bash
python3 scripts/editor_bridge_cli.py game get-many Main/Player Main/Player \
    --props global_position rotation.y
```

## The Drive Loop (core pattern)

```
1. PREAMBLE:  game ping  (bridge reachable?)
2. START:     game watch --nodes <node> --props '<[props]>' --hz 30
3. INJECT:    game hold <key>            (start the input you want to test)
4. OBSERVE:   sleep <n>; game sample --limit N
              -> does the invariant hold? (compare sample values across frames)
5. ADJUST:    if not converged -> change held input / release / re-hold; go to 4.
              if converged -> go to 6.
6. CLEANUP:   game release <key> (every key you held) ; game telemetry-stop
```

Always: **cap the loop** (max iterations / stop condition), and **release every key you
held** before finishing.

## Quick Reference

| Step | Command | Notes |
|------|---------|-------|
| preflight | `game ping` | bridge must be reachable first |
| hold | `game hold <key>` | drives polling controllers |
| release | `game release <key>` | **always** release when done |
| check held | `game held-keys` | what's currently held |
| sample | `game watch …` then `game sample --limit N` | observe motion over frames |
| stop sampling | `game telemetry-stop` | discards the buffer |
| batch read | `game get-many <paths…> --props <props…>` | one round-trip |
| disable retry | `game … --no-retry` | only on idempotent reads |

## Common Mistakes

- **Driving with `game key` on a polling controller** → nothing moves. Use `game hold`.
- **Firing a burst of `game` calls in one block** → responses lag / misalign; the single-client
  bridge can drop. Space them out (`sleep 2` between each) or use separate tool calls.
- **Holding a key and never releasing it** → the controller stays stuck. Always `game release`.
- **Asserting on a single `game get`** → that's a snapshot, not motion. Use `watch` + `sample`.
- **Letting the telemetry buffer overflow** → it caps at ~600 samples and rolls; sample in time.
- **`time-scale 0.0`** → crashes the game (use `0.5` minimum).
- **Trusting the first sample after a mutation** → the response can be one step behind; re-read
  `held-keys` / `sample` to confirm the mutation actually applied.
