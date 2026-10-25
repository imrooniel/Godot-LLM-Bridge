# Reconciliation Ledger — Task 1 (upstream MW bridge code to community)

Port of the MergingWorlds (MW) `bridge/` tree into this community repo, performed
2026-10-25 as Task 1 of the community-edition program.

- **Source snapshot:** MW working tree at `d524453e` (MW `git log` holds the
  per-change detail; `bridge/` was copied from that snapshot).
- **Method:** wholesale copy of `MW/bridge/ → bridge/`, no deletes, per the
  Task 1 brief. Excluded from the copy: `bridge/cli/run_tests.sh` (→ MW
  `tools/bridge-harness/` in Task 7), `bridge/tests/test_lua_vm_file.gd` +
  its orphan `.uid` (→ MW in Task 7; the brief excluded the `.gd`, its `.uid`
  was excluded too so no orphan resource id is introduced), and all
  `__pycache__/` directories.
- **Community-only files preserved (zero writes):** `bridge/game/example/`
  (4 scripts + `.uid`s), `bridge/game/GUIDE.md`, `bridge/game/README.md`,
  `bridge/README.md` (last three identical in both repos).
- **Allowed scrubbing:** `bridge/tests/test_cli.py` — sample method name
  `combat_snapshot` → `query_game_state` (3 occurrences). No other
  MW-string changes; generalization is Tasks 2–4.

Provenance lines: `path — <MW source commit(s) or "merge">`.

## New files

- `bridge/cli/cli_proc.py` — MW 279ff0a5 (introduced), grown through the B/S-series chain to d524453e (S5/S6 helpers in df2e0ed6/2f9ce595/040c9c05, S8 in df5e423e, S4 in ccdba09b, S3/S15 in 8e82c794/c2486a3b)
- `bridge/tests/test_cli.py` — MW 279ff0a5 (introduced), grown through the same chain to d524453e (superset of PR #1's version; scrubbed sample name per brief)
- `bridge/editor_bridge/commands/action_debugger_clear_breakpoints.gd` (+`.uid`) — MW 1cdb8688 (C8/B1/C7)
- `bridge/editor_bridge/commands/_dap_control.gd` (+`.uid`) — MW fbdfddbb (F14-4/F14-5)
- `bridge/tests/test_bridge_context.gd` (+`.uid`) — MW ccdba09b (S4)

## Modified code files

- `bridge/cli/editor_bridge_cli.py` — merge of the B/S-series chain: a5bdbcfa (B2/B5/B6), 1ad5e8d0 (A5/B8), ef762e4a (B10/C7/C6), 9d5a5fca (H1,H2,Q1,Q2,T4-m5), S1 recover (fd50a8f8), S5 restart force-kill (df2e0ed6/040c9c05), S6 launch --force (2f9ce595/18abad1b/e7b038bd), S8 suite-result (df5e423e/f04d5045), S10 (b2c2d772), S3 (8e82c794), S15 (c2486a3b), S7 (285f5ba1), S14 (84b35a5a), +88c770b7 read-only-rpc list
- `bridge/autoloads/debug_bridge.gd` — a5bdbcfa (B7/B9 unpausable timers, per-instance log), fc6a568c (Lua traceback + logs --tail), 6278ce94 (F14-3), b2c2d772 (S10 mods-loaded), 285f5ba1 (S7 lua-api)
- `bridge/editor_bridge/editor_bridge.gd` — S16 compile-error surfacing (43a8d812) over the C-series self-healing base (cbf956bb/9d5a5fca)
- `bridge/editor_bridge/bridge_context.gd` — F14-4/F14-5 ctx.require_dap() (fbdfddbb), S4 make_error carries reason/suggested (ccdba09b), tighten (3fa6035c)
- `bridge/editor_bridge/dap_session.gd` — B10/C7/C6 attach-race + out-of-order + multi-instance abort (ef762e4a), H1/H2 follow-ups (9d5a5fca), C8 stale-breaked reset (1cdb8688)
- `bridge/editor_bridge/game_proxy.gd` — B4/C1 reachability + discovered port (a5bdbcfa/1ad5e8d0), H1 stale-port reset (9d5a5fca), C8 (1cdb8688)
- `bridge/editor_bridge/commands/action_debugger_attach.gd` — fbdfddbb (ctx.require_dap), 9d5a5fca (attach outbox guard), cbf956bb (C8 recover)
- `bridge/editor_bridge/commands/action_debugger_{break,continue,detach,launch,pause,step_into,step_out,step_over,unbreak}.gd` — merge (table-driven `_dap_control` refactor, fbdfddbb)
- `bridge/editor_bridge/commands/query_debugger_{breaks,eval,output,stack,state,vars}.gd` — merge (table-driven `_dap_control` refactor, fbdfddbb)
- `bridge/editor_bridge/commands/action_editor_close.gd` — identical to PR #1 version (C2/A6 stop-then-quit); already in MW via 920c72e7-era layout port
- `bridge/editor_bridge/commands/action_scene_play.gd` — identical to PR #1 version (C1 orphan-port guard)
- `bridge/tests/test_bridge.gd` — identical to PR #1 version (B4/B7/B9 checks)

## `.uid` files (bulk)

All modified `bridge/**/*.uid` — merge: wholesale copy replaced the community
uid set (regenerated locally in d28324e) with the MW snapshot's uid set
(regenerated in MW 920c72e7). Byte-parity with the MW snapshot was the goal of
the brief's rsync; no `uid://` references exist in this repo to any bridge
script (only `scenes/main.tscn` carries its own scene uid), so the swap is
inert. New-file `.uid`s (`_dap_control.gd.uid`,
`action_debugger_clear_breakpoints.gd.uid`, `test_bridge_context.gd.uid`)
arrived with their scripts.

## Not copied (deliberate)

- `bridge/cli/run_tests.sh`, `bridge/tests/test_lua_vm_file.gd` (+`.uid`) —
  Task 7 (MW `tools/bridge-harness/`); `__pycache__/` — build artifact.
- MW-root `AGENTS.md` / `.tmp/` operational notes — not part of `bridge/`.

## Known MW-specific residue (Tasks 2–4 generalization targets, per brief)

- `editor_bridge_cli.py` / `debug_bridge.gd`: `mods-loaded` + `lua-api` game
  commands and their handlers (MW `ModLoader`/`LuaVM` autoloads; handlers
  degrade gracefully when absent), `combat_snapshot`/`combat_ai_trace` in the
  read-only-RPC allowlist and `--method` help text.
- `bridge/skills/**/SKILL.md`: unchanged by this task (identical in both
  repos); they still lack PR #1's docs (time-scale correction,
  `debugger clear-breakpoints`, self-healing section) — re-mine in the
  skills/docs tasks.
- `bridge/cli/editor_bridge_cli.py`: `change-scene` parser help names
  `combat._start_from_config` (MW combat flow); generalize to a game-agnostic
  description in Tasks 2–4.
- `bridge/autoloads/debug_bridge.gd`: `_cmd_game_status` reports
  `in_combat` derived from a hardcoded `/root/Main` node check; generalize
  the status field (or make it project-configurable) in Tasks 2–4.
- `res://scenes/combat.tscn` doc-example references in `editor_bridge_cli.py`
  usage docstring and command-script headers
  (`query_scene.gd`, `query_scene_tree.gd`, `action_scene_open.gd`,
  `action_scene_reload.gd`); replace with a neutral example scene path in
  Tasks 2–4.
