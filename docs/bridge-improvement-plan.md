# Bridge Improvement Plan

_Draft v2 — **IMPLEMENTED & VERIFIED** (2026-09-06). v1 was generated from `docs/bridge-friction-log.md` + a surface audit of `autoloads/debug_bridge.gd` and `scripts/editor_bridge_cli.py`. v2 incorporated **three subagent source audits** (Godot engine source, the bridge source, and opencode skill conventions) that **corrected two of v1's core assumptions** (held-input and flakiness). All phases are now implemented, headless-tested (**172 checks / 0 failures**, up from 163), and the drive loop verified **live** against the running game. Evidence cited inline as `file:line`._

### Implementation status (2026-09-06)
| Phase | Status | Notes |
|-------|--------|-------|
| 0 spike | ✅ done | Confirmed held-input didn't move player (live); `batch_get` not yet present; drops = single-client + no retry |
| 1a held-input | ✅ done & live-verified | `held_keys` set + `is_action_held`; player ORs bridge-held actions in. **Live: player moved z=5.0→9.34** under `game hold W` |
| 1b batch read | ✅ done & live-verified | `_cmd_batch_get` + `game get-many`; dotted props resolved. Live: one round-trip returned both items as objects |
| 2 telemetry | ✅ done & live-verified | frame-counter-gated ring buffer, `_process` sampler, `watch`/`sample`/`telemetry-stop`. Live: samples captured player motion |
| 3 CLI retry | ✅ done | bounded read-only retry (3×, idempotent reads only); `--no-retry` |
| 4 screenshot | ✅ done | `--wait-ms` settle + uniform `{ok,…}` envelope on both screenshot commands |
| 5 drive skill | ✅ done | `.opencode/skills/drive/SKILL.md` (auto-discovered) + `HUMAN_GUIDE.md` updates |

**Bugs caught during implementation (DAP / live, not headless):**
- `_actions_for_keycode` initially filtered on the event's `pressed` flag — but `[input]` serializes key events with `pressed=false`, so nothing matched. Fixed: match on keycode alone (specific-keycode preferred over physical).
- `_read_prop` used `container.has_method("get")` → **invalid on `Vector3`** ("Nonexistent function 'has_method' in base 'Vector3'"). `Object.class_has_method`/`can_instance` are **not statics** in 4.8, and `Callable(vec3, "get")` is an **invalid signature** (Vector3 isn't a dispatch target). Final fix: read vector/transform sub-fields via **direct member access** (`r.y`, `t.origin.x`) with a `typeof()` type dispatch.
- **Lesson:** the DAP stack-trace on a runtime exception (surfaced by the bridge's own crash reporter) caught bugs headless tests could not — a strong argument for the telemetry/replay phase.

---

## 0. Why this plan — and what the research corrected

The friction log's headline recommendation — "the bridge needs **held-input injection**" — was written **without knowing the bridge already has `inject_key`/`game key`**. A v1 surface audit showed the gap was narrower than assumed. This v2's source audits then **proved two of v1's assumptions wrong**:

### Correction #1 — `push_input` does NOT drive polling-based input
`Viewport::push_input()` dispatches into the `_input`/`_unhandled_input` **callback** pipeline but **does not mutate the `Input` singleton's polled key-state** (`is_key_pressed` / `is_action_pressed`). That state is only inserted/erased in the platform DisplayServer's real-input path:
- press insert / release erase: `core/input/input.cpp:883` / `:885`
- `is_key_pressed` reads the set: `core/input/input.cpp:358`
- `parse_input_event` (the only thing that calls the insert/erase) is invoked by DisplayServers, **not** by `push_input`: `core/input/input.cpp:1603`
- `push_input` → `_call_input_pause(...)` only: `scene/main/viewport.cpp:3499`, `:3547`

**Implication:** our RPG reads `Input.get_vector(...)` (a polling/action API). The existing `game key W` will fire `_input` callbacks but **will not move the player**. Held-input for a polling game needs the bridge to maintain a **`held_keys` set the game code polls**, *in addition to* still pushing the events (so `_input`-based code also works). **This is a real build item, not "document + stabilize."**

### Correction #2 — "flakiness" is serialization + timeout + no retry, not reconnects
The CLI **has no socket**. Transport is CLI → **editor** (file-mailbox `.tmp/bridge/{inbox,outbox,state.json}`, parallel-safe) → **editor's persistent TCP peer** to the game (`game_proxy.gd:22`) → the game's **single-client** socket (`debug_bridge.gd`). There is no per-call reconnect. The real causes of the observed `game get` drops are:
- **single-client serialization** at two independent gates: the editor proxy allows one in-flight request (`game_proxy.gd:42-43`), and the game accepts a new client only when none is active (`debug_bridge.gd:72-79`).
- **editor proxy timeout = 10 s** (`game_proxy.gd:19`), game-side idle close = 60 s (`debug_bridge.gd:12`).
- **zero retry anywhere**: the CLI retries reading the outbox file but **never re-sends** the request (`editor_bridge_cli.py:250-260`); the proxy timeout is terminal (`game_proxy.gd:95-98`).

**Implication:** a "persistent CLI daemon" would gain **no** parallelism (the game is single-client by design) and would re-implement the editor proxy. The correct fix is a **CLI-side bounded, read-only retry wrapper** (Q2 below).

### Other findings that sharpen the design
- **`batch_get` is callable today with zero CLI code** via the generic `game rpc batch_get --json-params '{...}'` (`editor_bridge_cli.py:760-763`). Only the GDScript handler is genuinely new; a `game get-many` subcommand is optional UX.
- **Telemetry cadence:** use the frame counter `Engine.get_process_frames() % N == 0` (there is **no** `Engine.get_frames_count()`; `get_process_frames` is bound at `core/core_bind.cpp:2127`). Use `Engine.get_frames_per_second()` to derive `N`. Reuse `Performance.get_monitor(...)` for engine metrics (`main/performance.cpp:251`) rather than hand-rolling.
- **Screenshot:** `ViewportTexture.get_image()` returns the **last rendered** frame (`scene/main/viewport.cpp:201`) — blank if never rendered / not settled. A settle `await` is required, not optional.
- **Skill conventions (opencode):** SKILL.md needs only `name` + `description` frontmatter; **auto-discovered** from `.opencode/skills/<name>/SKILL.md` (no `opencode.json` change). `description` is third-person, "Use when…" + **Trigger keywords**, and must **not** summarize the workflow (the body does). Co-located helper scripts are referenced by project-relative path.

**Scope:** bridge code (Godot autoload + Python CLI + headless tests) **+ agent workflow** (an opencode `drive` skill + HUMAN_GUIDE). **Generality:** general-purpose (any Godot project); this RPG is only the testbed. **Ordering (chosen):** spike → held-input+batch → telemetry+replay → CLI stability → agent workflow → screenshot.

---

## Phase 0 — Verification spike (build nothing; cheap)

**Goal:** confirm the engine-level findings against the *live* game so Phases 1–3 build only what's genuinely missing. (Most findings are now source-proven; the spike is a guard, not a discovery step.)

- **0.1 Held-input negative test (confirms Correction #1).** With the game running: `game key W` → `game get Player global_position` ×3 over ~2 s → `game key W --release`.
  - **Expected per source:** position **static** (the player uses `Input.get_vector`, a polling API, which `push_input` doesn't feed).
  - If it *does* move, our source read is wrong and Phase 1a shrinks to "document." If static (expected), Phase 1a's `held_keys` build is confirmed necessary.
- **0.2 Batch round-trip (confirms the zero-CLI-code path).** One `game rpc batch_get --json-params '{"items":[{"path":"Player","prop":"global_position"},{"path":"Player","prop":"rotation.y"}]}'` — confirm one round-trip, no retry.
- **0.3 Drop-rate measurement.** Run a loop of ~20 `game get` calls; count timeouts vs. the 10 s proxy budget. Confirms the flakiness is timeout/serialization, not reconnect.

**Exit criteria:** a short addendum to this plan with pass/fail per spike and the concrete implication for Phases 1–3.

---

## Phase 1 — Held-input (the real fix) + batch reads

- **1a. Held-input via a `held_keys` set the game polls.**
  - Godot autoload: add `var _held_keys: Dictionary = {}` (keycode → true). `_cmd_hold_key` sets the entry *and* still calls `get_viewport().push_input()` (so `_input`-based code also sees it); `_cmd_release_key` clears it *and* pushes the release. Add a public `is_key_held(key: Key) -> bool` (and an `is_action_held(action: String) -> bool` helper that maps through `InputMap`).
  - **Game-side change (one-line, in the controller):** `scenes/player.gd` reads `Input.get_vector(...)`. Keep that **or** add a debug hook: `if (GameBridge/DebugBridge).is_key_held(KEY_W): thrust += 1`-style override, gated by a `debug_input` flag so it only applies when the bridge is driving. *Decision point — see Open question A.*
  - CLI: `game hold <key>` / `game release <key>` (thin wrappers over `hold_key`/`release_key`).
  - **Do NOT** attempt an engine-side change to make `push_input` mutate `Input` state — out of scope (would require a Godot patch).
- **1b. Batch read (one round-trip).**
  - Godot: `_cmd_batch_get` in `debug_bridge.gd` — loop `params["items"]` (`[{node,prop},…]`) → `[{node,prop,value,type} | {node,prop,error}]`, **reusing** `_resolve_node`, `_has_property`, `_variant_to_serializable`, `_variant_type_name` exactly as `_cmd_get_property` does (`debug_bridge.gd:480-490`, `:329-346`, `:382-477`). A bad item is collected, not a hard error. Register in `_init_handlers` (`:260-292`).
  - CLI: **optional** `game get-many` (`GAME_COMMANDS` entry + `g_sub.add_parser`); the generic `game rpc batch_get --json-params` already works with zero CLI code. Keep item count bounded (synchronous main-thread).
- **Tests:** headless `test_batch_get.gd` (multi-node, missing-prop error, 50-item payload, no abort on one bad item). `held_keys` covered by a headless check that `is_key_held` reflects hold/release.

---

## Phase 2 — Temporal telemetry + replay  *(the highest-value gap)*

**Why here:** movement/animation/root-motion are time-series. A one-shot `get` can't show a teleport, a stuck rotation, or a back-pedal artifact — exactly the bugs we could only catch via user play-test. This is the capability that would let the agent **observe motion**.

- **2a. Pull-based sampling with a ring buffer.**
  - State (module-level, near `debug_bridge.gd:248`): `_telemetry_active: bool`, `_telemetry_nodes: Array` (resolved `Node` refs + prop lists), `_telemetry_frame_step: int`, `_telemetry_buf: Array` (capped ring), `_TELEMETRY_MAX_SAMPLES`.
  - New `func _process(delta)` in `debug_bridge.gd` (none today). Gate: `if _telemetry_active and Engine.get_process_frames() % _telemetry_frame_step == 0:`. **Resolve node refs once at `telemetry_start`** (not per tick); re-validate with `is_instance_valid`. Read props via `node.get(prop)`; store **Variant** dicts in the buffer (do **not** JSON-encode on the tick). Include a few `Performance.get_monitor(...)` + `Engine.get_frames_per_second()` per sample.
  - Handlers: `telemetry_start({nodes:[{path,props:[…]}], hz})` (compute `_telemetry_frame_step = max(1, int(Engine.get_frames_per_second() / hz))`, clear buffer, activate) / `telemetry_stop` / `telemetry_sample({limit?})` (materialize + return, honoring cap). All registered in `_init_handlers`.
  - Cost mitigation at 30 Hz: refs resolved once; buffer stores Variants; only `telemetry_sample` stringifies; keep `hz` modest (the frame-counter gate is fps-adaptive).
  - CLI: `game watch` (`telemetry_start`) + `game sample` (`telemetry_sample`); `GAME_COMMANDS` + `g_sub.add_parser` each (pattern: `editor_bridge_cli.py:588-627`, `:695-770`).
- **2b. Replay + assertions (higher value, optional).**
  - `telemetry_record <name>` → dump the buffer to `.tmp/bridge/telemetry/<name>.json`.
  - A small assert helper (GDScript test or Lua) that reads a captured buffer and checks invariants (e.g. "position.z never jumps > X in one frame", "rotation.y stays within ±90° of aim") — turning motion bugs into **reproducible, headless-runnable checks** instead of live play-test.
- **Tests:** `test_telemetry.gd` — start/sample/stop shape, ring cap, `frame_step` derived from hz, no buffer growth when stopped, freed-node guard.

---

## Phase 3 — CLI stability (bounded retry, no daemon)

- **3a. CLI-side bounded retry wrapper (per Correction #2).**
  - Wrap the `game` branch's `client.rpc(...)` (`editor_bridge_cli.py:957-961`) with a bounded retry (e.g. 3 attempts, short backoff) **only for idempotent reads** (`get`/`batch_get`/`inspect-tree`/`scan-ui`/`screenshot`/`game-status`). For **mutations** (`set`, `call`, `inject_*`, `hold`/`release`), either do **not** blind-retry, or re-check liveness (`game ping`/`game-status`) before re-sending to avoid double-apply.
  - `--no-retry` escape hatch; surface the final timeout error cleanly.
  - **Do NOT** add a persistent CLI daemon — it re-implements the editor proxy and gains no parallelism (game is single-client at `debug_bridge.gd:72-79` + `game_proxy.gd:42-43`).
- **3b. Health:** extend `game_status` to report connection age + telemetry sampler state (Phase 2).
- **Tests:** CLI unit test for the retry wrapper (simulated transient failure → succeeds on 2nd/3rd attempt; gives up at cap with a clear error; mutations not blind-retried).

---

## Phase 4 — Screenshot hardening  *(lowest priority, static-only)*

- Make `screenshot` / `screenshot-b64` reliable (per source: they currently return a partial envelope and never settle — `debug_bridge.gd:538-546`, `:722-732`):
  - Add optional `wait_ms`; if > 0, `await get_tree().create_timer(wait_ms/1000.0).timeout` **before** `get_image()` (handlers already support `await` — `_dispatch`/`_handle_request` await; `_cmd_start_scene` uses `create_timer`, `:872`).
  - Return a **uniform** envelope on both paths: `{"ok":true,"path":…}` / `{"ok":true,"b64":…,"width":…,"height":…}` / `{"ok":false,"error":…}` — stop using `_make_error` for the failure path.
  - CLI: add `--wait-ms` to both parsers (`editor_bridge_cli.py:734-737`) + `GAME_COMMANDS` lambdas (`:609-610`).
- Document explicitly (per friction log): **a still frame only catches static properties** (position, rotation, sprite, UI) — **not motion.** Pair motion work with Phase 2.
- **Tests:** headless screenshot returns the structured shape; capture path writable.

---

## Phase 5 — Agent workflow: the `drive` skill (opencode)

Per the opencode audit: **auto-discovered** from `.opencode/skills/drive/SKILL.md` (no `opencode.json` change). Minimal `name` + `description` frontmatter; `description` is third-person "Use when…" + **Trigger keywords** and does **not** summarize the loop.

- **5a. Skill:** `.opencode/skills/drive/SKILL.md` — the closed loop the friction log named: **inject held input → sample telemetry → assert invariant → adjust → repeat**, bounded. Sections mirror `debug-bridge/SKILL.md`: Pre-flight (`ping` / `game ping`), the Drive Loop, Command Reference (bash blocks), Quick-Reference table, Common Mistakes.
  - Commands used: `game hold <key>` / `game release <key>` (Phase 1a), `game watch` / `game sample` (Phase 2), `game get` / `game get-many`, `game set`.
  - Note the held-input caveat in the body: the game must poll `is_key_held` (Phase 1a) — `game key` alone won't move a polling controller.
- **5b. Optional co-located helper:** `.opencode/skills/drive/drive.sh` (or `scripts/drive.py`) wrapping the loop; referenced by project-relative path (loader prints the base dir + lists co-located files).
- **5c. Docs:** add `game hold`/`game release`, `game get-many`, `game watch`/`game sample`, `--wait-ms`, and the `--no-retry` behavior to `docs/HUMAN_GUIDE.md`.
- **No subagent required** for v1 (a sandboxed `mode: subagent` wrapper is a later option if permission isolation is wanted — mirrors `task-management` + `TaskManager`).
- **Testing the skill:** confirm the `description` triggers on a real "drive the game" prompt; confirm every `bash` command in the body runs against a running game (`game ping` first).

---

## Cross-cutting

- **Every phase:** headless test(s) under `tests/`, run via `tests/test_suite.gd` (currently 163 checks / 0 failures — keep it green).
- **CLI help parity:** any new subcommand gets `--help` + a `HUMAN_GUIDE.md` example.
- **Backwards compatible:** all additions; existing handlers/commands unchanged.
- **No new dependencies** beyond Godot + Python stdlib.

## Phasing / effort (updated)

| Phase | Value | Effort | Depends on |
|-------|-------|--------|-----------|
| 0 spike | High (de-risks everything) | Tiny | — |
| 1 held-input+batch | **High** (closes the real input gap) | Small–Medium (1a has a game-side hook) | 0 |
| 2 telemetry+replay | **Highest** (closes the real observation gap) | Medium–Large | 0, 1 |
| 3 CLI stability | Medium (removes the annoyance) | Small | 1 |
| 4 screenshot | Low (static-only) | Tiny | — |
| 5 `drive` skill | Medium (leverages 1–3) | Small | 2, 3 |

**Recommended order:** 0 → 1 → 2 → 3 → 5 → 4. (Screenshot last — least useful for motion, nearly trivial.)

## Open questions — status after research
- **(1) Held-input mechanism — RESOLVED:** `push_input` alone is insufficient for polling input (Correction #1). Build a `held_keys` set the game polls + keep pushing events. No engine patch.
  - *Remaining decision (A):* how the controller consumes it — (i) a `debug_input` flag in `player.gd` that ORs bridge-held keys into the thrust/turn input, or (ii) a general `DebugBridge.is_action_held(action)` the game calls. (i) is local/simple; (ii) is reusable. Recommend (i) for v1.
- **(2) Persistent session — RESOLVED:** no daemon; CLI-side bounded read-only retry wrapper (Correction #2).
- **(3) Pull vs push telemetry — RESOLVED:** pull-based, frame-counter gated (`Engine.get_process_frames() % N`), `Performance.get_monitor` for engine metrics, refs resolved once at start.
- **(New, B) Editor proxy 10 s budget for `telemetry_sample` / large `batch_get` — RESOLVED (2026-09-05):** keep the existing 10 s budget, add **no** new per-command timeout. We are already changing a lot; a timeout entry is unnecessary churn. Instead **bound the request sizes** — `batch_get` item count, telemetry `hz`/`limit` — so a single synchronous main-thread op stays comfortably under 10 s. (Default caps chosen in Phase 1b/2.)
