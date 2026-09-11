# AGENTS — Godot LLM Bridge (community)

You are working in a **Godot 4** project that contains the **Godot LLM Bridge**: a
file-mailbox bridge between the Godot editor and external CLI tools / LLMs, for
programmatic game-state inspection, input driving, and real DAP debugging.

This repo is the **generic, game-agnostic** bridge. The `bridge/` folder is
portable: it contains **no game-specific code** and can be dropped into any Godot 4
project. Keep it that way.

## Repo layout

- `bridge/autoloads/` — `debug_bridge.gd` (the in-game runtime channel; a single
  autoload) + `debug_log_collector.gd`.
- `bridge/editor_bridge/` — the `@tool` editor addon: the mailbox server, DAP
  session, game proxy, and `commands/` (each command is a script located by name).
- `bridge/human_edit/` — the `@tool` editor plugin that captures a human's editor
  edits as content deltas (spec C4).
- `bridge/contract/` — `bridge_contract.gd`: the single shared definition of the
  response envelope (`ok` / `error` / `data`), the one place the envelope is defined.
- `bridge/cli/` — `editor_bridge_cli.py`: the command-line front-end that drives the
  bridge.
- `bridge/skills/` — agent skill docs (debug-bridge, editor-bridge, drive, human-edit).
- `bridge/tests/` — headless self-tests (run with `godot --headless --script …`).
- `bridge/game/` — how to hook in your own game: `GUIDE.md` (the contract) +
  `example/` (a minimal worked sample).
- `bridge/README.md` — install + usage.
- `scenes/`, `scripts/main.gd` — the minimal project scene that hosts the bridge.

## Two independent channels (do not conflate)

| Channel | Script | Lifecycle | What it does |
|---|---|---|---|
| **Editor** | `bridge/editor_bridge/editor_bridge.gd` (the `@tool` addon) | Runs in the editor process | File-mailbox JSON-RPC; `action_*` / `query_*` / `logs_*` commands; DAP debug session; proxies scene/game ops to the runtime. |
| **Runtime** | `bridge/autoloads/debug_bridge.gd` (the autoload) | Runs in the *game* process | Held-input drive, state read, telemetry, runtime error capture. Reached either over TCP `:5555` or as a `gd-eval` expression inside an editor command. |

They are separate processes; an editor command cannot see the runtime node by name
and vice versa. See `bridge/skills/debug-bridge/SKILL.md` for the full boundary table.

## Invariants (enforced — do not break)

- **Game-agnostic:** nothing under `bridge/` may reference a specific game's
  scenes, scripts, autoload names, or assets. Use generic placeholders in docs and
  examples. `bridge/game/example/` is the only place a concrete sample lives, and it
  is explicitly a *sample*.
- **Harness-agnostic:** the bridge is driven over a plain file mailbox / CLI. It must
  not assume a specific LLM harness, SSE, or tooling.
- **Verified readback:** a "done" is a *verified* readback (compile gate +
  `godot-status` + the relevant `query_*`), not a claim. See `bridge/game/GUIDE.md`.

## Verify before you claim it works

- **Compile gate (editor):** `godot --path <repo> --headless --check-only --script res://bridge/editor_bridge/commands/<cmd>.gd`
- **Runtime compile gate:** same with `--script res://bridge/autoloads/debug_bridge.gd`
- **Python CLI:** `python3 -m py_compile bridge/cli/editor_bridge_cli.py`
- **Self-tests:** `godot --path <repo> --headless --script res://bridge/tests/<test>.gd`
  (bridge_contract_test, human_edit_test, script_run_test, scripts_check_test, test_bridge)

## Conventions

- GDScript 4, `snake_case` for functions/variables, `PascalCase` for class/script
  names. Small, focused scripts (< ~100 lines); one command per file in
  `bridge/editor_bridge/commands/`.
- New commands: add `<name>.gd` (locatable by file name) + its `.uid` sidecar, then
  wire the CLI verb in `bridge/cli/editor_bridge_cli.py` and document it in the
  relevant `bridge/skills/*/SKILL.md`.
- Response envelope: always `{ "ok": bool, "error": {...} | null, "data": ... }` per
  `bridge/contract/bridge_contract.gd`.
