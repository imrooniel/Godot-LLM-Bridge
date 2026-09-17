#!/usr/bin/env python3
"""Pure, unit-testable process helpers for the EditorBridge CLI.

No live-editor dependency: these operate on `ps` output strings and path
strings so they can be unit-tested (bridge/tests/test_cli.py) without
launching Godot. The CLI (editor_bridge_cli.py) uses these for launch
pre-flight, orphan detection, and pid liveness.

Findings addressed: A2 (proc matching), A3 (path validation), C1/C2
(orphan game detection), C3 (pid liveness vs heartbeat age).
"""
import os
import subprocess
import sys


def parse_ps(ps_out: str, pid: int) -> list:
    """Parse `ps -eo pid=,args=` output into a list of (pid:int, cmdline:str).

    Robust to: blank lines, lines shorter than 2 fields, non-int pids,
    and `ps` width-truncation (long cmdlines simply end early — we still
    get the prefix, which is what matching needs).
    """
    procs = []
    for line in ps_out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        try:
            p = int(parts[0])
        except ValueError:
            continue
        if p == pid:
            continue
        procs.append((p, parts[1]))
    return procs


def is_godot_editor(cmdline: str) -> bool:
    """True if the cmdline is a Godot EDITOR (not a game, not the project
    manager).

    Classified on FLAGS, never on the binary filename: the game and the editor
    are launched from the SAME binary (a custom build's name may not even
    contain "godot"), so the only reliable editor marker is the `--editor` flag
    (an editor invocation always carries it; an editor-spawned game never does).
    Fix for A2(a): the old binary-name + bare-path needle matched game
    processes too, and a custom-named binary would have made it a silent no-op.
    """
    tokens = cmdline.split()
    return bool(tokens) and "--editor" in tokens


def is_godot_game(cmdline: str) -> bool:
    """True if the cmdline is a Godot GAME process spawned by the editor.

    Classified on FLAGS: every editor-spawned game carries `--editor-pid <pid>`
    (editor_run.cpp:70-71) and never `--editor`; the editor carries `--editor`
    and never `--editor-pid`. Keying on `--editor-pid` (rather than "no
    `--editor` + has `--path`") is robust to a manually-run bare
    `godot --path X` (no `--editor-pid`) and to custom-named binaries.
    `find_godot_procs` additionally filters on the `--path` project match.
    Fix for A2(a).
    """
    tokens = cmdline.split()
    return bool(tokens) and "--editor-pid" in tokens and "--editor" not in tokens


def proc_path_arg(cmdline: str) -> str:
    """Return the value of the first `--path <value>` in a cmdline, else "".

    Handles the engine's `%20`-encoded spaces and trailing slashes so the
    result can be normalized and compared to the project root (fixes A2(b):
    a truncated or normalized `--path` must still be detectable)."""
    tokens = cmdline.split()
    for i, t in enumerate(tokens):
        if t == "--path" and i + 1 < len(tokens):
            return tokens[i + 1].replace("%20", " ")
    return ""


def same_path(a: str, b: str) -> bool:
    """Path equality after abspath normalization (handles trailing slash,
    `..`, `%20`). Used to decide whether a proc's `--path` targets THIS
    project."""
    if not a or not b:
        return False
    na = os.path.normpath(os.path.abspath(a))
    nb = os.path.normpath(os.path.abspath(b))
    return na == nb


def find_godot_procs(project_path: str, ps_out: str = None, pid: int = None):
    """Return {"editors": [(pid, cmdline)], "games": [(pid, cmdline)]} for
    Godot processes whose `--path` targets `project_path`.

    `ps_out`/`pid` are injectable for tests. When `ps_out` is None we run
    `ps -eo pid=,args=`. Degrades to empty dicts on any ps failure (the CLI
    then proceeds without pre-flight, same as today).

    The fix for A2: editors and games are matched SEPARATELY and correctly
    (an editor is `--editor`; a game is `--path` without `--editor`), and a
    proc only counts when its `--path` resolves to `project_path` — so a
    truncated/other-project path does NOT falsely match, and a game process
    is no longer mistaken for an editor.
    """
    if ps_out is None:
        try:
            ps_out = subprocess.run(["ps", "-eo", "pid=,args="],
                                    capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return {"editors": [], "games": []}
    if pid is None:
        pid = os.getpid()
    editors, games = [], []
    for p, cmdline in parse_ps(ps_out, pid):
        path = proc_path_arg(cmdline)
        if not same_path(path, project_path):
            continue
        if is_godot_editor(cmdline):
            editors.append((p, cmdline))
        elif is_godot_game(cmdline):
            games.append((p, cmdline))
    return {"editors": editors, "games": games}


def pid_alive(pid: int) -> bool:
    """True if `pid` is a live process on this host (signal-0 probe).

    This is the fix for C3: restart()'s death-wait must check PROCESS
    liveness, not the heartbeat age in state.json (a modal-blocked editor
    can keep a fresh heartbeat while the user is stuck on a dialog, or go
    stale while still alive)."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists but owned by another user
    except (OverflowError, ValueError):
        # pid outside the platform's range (e.g. > INT32_MAX) can never be a
        # live process — os.kill can't even be asked about it.
        return False
    except OSError:
        return False


def validate_project_path(project_path: str) -> str:
    """Return an error string if `project_path` is not a valid Godot project
    dir (no `project.godot`), else "".

    Fix for A3: launch() must fail fast on a bad path instead of letting
    Godot silently fall back to the project-manager (no heartbeat → 300 s
    timeout → orphan)."""
    if not project_path:
        return "project path is empty"
    if not os.path.isdir(project_path):
        return "project path is not a directory: %s" % project_path
    if not os.path.isfile(os.path.join(project_path, "project.godot")):
        return "no project.godot in %s (wrong path? launch needs the project root)" % project_path
    return ""
