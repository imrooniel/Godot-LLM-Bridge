# Contributing to Godot LLM Bridge

## Access model

- **Collaborators** (write access): work on branches, open PRs.
  **`master` is owner-merge-only** — no self-merges, ever.
- **Everyone else**: fork + PR against `master`. PRs from forks are welcome
  and reviewed the same way.
- Bug fixes and features both start with an issue when the design isn't
  obvious (feature-request template). Small, obvious fixes can go straight
  to PR.

## Dev setup

### Linux/macOS (bash)

```bash
git clone https://github.com/imrooniel/Godot-LLM-Bridge.git
cd Godot-LLM-Bridge
# Point the CLI at your Godot binary (any one of):
echo "$HOME/path/to/godot" > .godot-editor-path   # project-local (gitignored)
export GODOT_EDITOR_BINARY=$HOME/path/to/godot    # env var
# ...or just have `godot` on PATH.
python3 bridge/cli/editor_bridge_cli.py launch    # opens the demo project
```

### Windows (PowerShell)

```powershell
git clone https://github.com/imrooniel/Godot-LLM-Bridge.git
cd Godot-LLM-Bridge
# Any one of:
Set-Content .godot-editor-path "C:\path\to\Godot_v4.x-stable_win64.exe"
$env:GODOT_EDITOR_BINARY = "C:\path\to\Godot_v4.x-stable_win64.exe"
# ...or have godot on PATH.
python bridge\cli\editor_bridge_cli.py launch
```

Use `python` on Windows, `python3` on Linux/macOS from here on.

## Test commands (all from repo root)

```bash
# Python CLI suite (stdlib unittest, no Godot needed)
python3 bridge/tests/test_cli.py

# Version consistency (VERSION == both plugin.cfg files)
python3 scripts/check_version.py

# GDScript suites (each prints PASS/FAIL and quits 0/1)
godot --headless --path . --script res://bridge/tests/bridge_contract_test.gd
godot --headless --path . --script res://bridge/tests/human_edit_test.gd
godot --headless --path . --script res://bridge/tests/script_run_test.gd
godot --headless --path . --script res://bridge/tests/scripts_check_test.gd
godot --headless --path . --script res://bridge/tests/test_bridge_context.gd
godot --headless --path . --script res://bridge/tests/test_bridge.gd
```

CI runs all of the above (ubuntu + Windows × Python 3.11/3.12 for the CLI
suite; pinned-stable Godot for the GD suites) plus an xvfb integration job
that drives the real editor and game end-to-end. Your PR must be green —
the checks that only run in CI (integration) are reviewed manually if they
flag.

Windows note: the GD suites and integration job run on Linux runners; on
Windows, at minimum keep `python bridge\tests\test_cli.py` green locally.

## Rules of the road

- **`bridge/` stays project-agnostic.** No game-specific code, scene paths,
  or autoload-name lookups inside `bridge/`. Projects extend the tool from
  THEIR code via `DebugBridge.register_handler(...)` (see
  `bridge/game/GUIDE.md`). PRs adding game strings to `bridge/` will be
  asked to move them.
- **Skills ship with CLI changes.** If you change the CLI surface
  (commands, flags, output shapes), update the canonical skills under
  `bridge/skills/` in the SAME PR. Downstream mirrors (e.g. consuming
  projects' `.opencode/skills/`) are copies — never edit those here.
- **Error contract.** Every CLI failure path emits the envelope
  (`code/message/reason/suggested`) — no bare tracebacks; new failure modes
  get a `suggested:` pointer to the next command.
- **Python stays stdlib-only** (≥3.9) in `bridge/cli/` and `scripts/`.
- **Godot support floor**: core bridge features must work on the CI-pinned
  stable; engine-newer features (e.g. 4.8 DAP) must answer structured errors
  on older engines, never crash. Update the README requirements table when
  this moves.

## Versioning & changelog

- `VERSION` at the repo root is the single source of truth;
  `python3 scripts/check_version.py` enforces it against both `plugin.cfg`
  files. Bump only in release-prep commits unless the owner says otherwise.
- Every PR adds a line to `CHANGELOG.md` under the unreleased heading.

## Fixing the bridge from inside a consuming project (subtree workflow)

Downstream projects (e.g. MergingWorlds) vendor this repo as a **git subtree**
under `bridge/`. When you hit a bug while working in such a project:

1. Fix it **here** (community repo) on a branch, PR, owner merge.
2. The consuming project pulls your fix:
   `git subtree pull --prefix=bridge https://github.com/imrooniel/Godot-LLM-Bridge.git master --no-squash`
3. Or if you fixed it inside the consuming project's `bridge/` prefix first,
   push it back up:
   ```bash
   git subtree split --prefix=bridge -b bridge-upstream
   git push bridge-upstream   # to THIS repo's remote (fork for strangers)
   # then PR bridge-upstream → master here
   ```

Never develop features by editing `bridge/` inside a consuming project long
term — upstream first, pull down after.

## Release flow (owner)

Tag `vX.Y.Z` from `master`, update `VERSION` + `CHANGELOG.md` in the release
commit, GitHub release notes summarize it. Consuming projects subtree-pull
tags too.
