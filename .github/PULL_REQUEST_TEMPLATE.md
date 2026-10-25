## What & why

<!-- One short paragraph: what changes, which problem it solves. Link issues. -->

## Checklist

- [ ] CI green (CLI matrix, GD headless, integration)
- [ ] `CHANGELOG.md` has a line for this change (under the unreleased heading)
- [ ] Skills updated if CLI surface changed (`bridge/skills/` is canonical;
      downstream mirrors like `.opencode/skills/` are NOT edited here)
- [ ] `python3 scripts/check_version.py` passes (if any version string moved)

## Scope guardrails (please respect)

- Nothing game-specific inside `bridge/` — the tool is project-agnostic;
  projects extend via `register_handler()` from THEIR code.
- Engine API use must stay within the supported Godot range (see README);
  4.8+-only features (DAP) must degrade with a clear error, not a crash.
