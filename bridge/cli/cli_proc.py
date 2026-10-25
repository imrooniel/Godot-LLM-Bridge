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
import re
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


def launch_should_refuse(procs: dict, force: bool = False) -> bool:
    """True iff a launch must be refused (S5). A running editor for THIS
    project blocks a second editor — unless `force` is set (restart() force-
    kills a lingering editor, so a stale pid is not a reason to refuse)."""
    if force:
        return False
    return bool(procs["editors"])


def should_kill_orphans(procs: dict, force: bool) -> bool:
    """True iff `launch --force` should SIGKILL the orphan game processes
    (S6). Only when `force` is set AND orphan games exist; a plain launch
    (force=False) only warns about them."""
    return force and bool(procs["games"])


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


# Signatures of GENUINE transport failures on the game command path. Anything
# else is a structured JSON-RPC error the editor returned (a logic error — the
# game was never touched). A carried `reason` in the transport set overrides
# the message text (S4: reason-aware classification).
TRANSPORT_MARKERS = ("timed out", "timeout", "connection", "disconnected",
                     "not running", "unreachable", "refused",
                     "previous request lost")


def is_transport_failure(message: str, reason: str = "") -> bool:
    """True iff a game-command error is a genuine transport failure (timeout /
    disconnect / bridge never reachable), as opposed to a structured error the
    editor answered with (policy rejection, bad node path, method-not-found, ...).

    Reason-aware: a `reason` in the transport set forces True (the structured
    signal wins over the message text); a structured `reason` (e.g.
    `method_not_found`) does not. Otherwise fall back to the message markers.
    """
    if reason in ("game_paused_or_dropped", "bridge_dropped", "transport"):
        return True
    low = message.lower()
    return any(m in low for m in TRANSPORT_MARKERS)


_REASON_CLASS = {
    "game_paused_or_dropped": "game_paused",
    "game_unreachable": "game_unreachable",
    "bridge_dropped": "bridge_dropped",
    "editor_not_running": "editor_down",
    "not_attached": "dap_not_attached",
    "not_broken": "dap_not_breaked",
    "method_not_found": "bad_request",
    "policy_rejected": "policy_rejected",
}
_CODE_CLASS = {
    -32603: "load_failed",
    -32601: "unknown_command",
    -32002: "dap_not_attached",
}


def error_class(reason: str, code="") -> str:
    """Normalize a carried `reason`/`code` into a stable `error_class` the
    LLM can branch on (S4). `reason` wins; else the editor's int `code`
    (which may arrive as a stringified int); else "unknown".

    `code` is polymorphic: an int or a stringified int (e.g. "-32603").
    """
    if reason in _REASON_CLASS:
        return _REASON_CLASS[reason]
    # code may be an int or a stringified int (e.g. "-32603"); normalize.
    try:
        c = int(code)
    except (TypeError, ValueError):
        c = code
    if c in _CODE_CLASS:
        return _CODE_CLASS[c]
    return "unknown"


_DAP_STATE_CHANGING = {"continue", "pause", "step-over", "step-into",
                      "step-out", "stack", "vars", "eval"}


def dap_needs_attach(cmd: str) -> bool:
    """True iff a `debugger <cmd>` requires an attached DAP session (S3).

    State-changing commands (continue/pause/step-*/stack/vars/eval) fail
    without an attach; read-only ones (state/breaks/...) and the attach
    action itself do not need a pre-attach. The CLI auto-attaches for the
    True set."""
    return cmd in _DAP_STATE_CHANGING


def dap_timeout_message(editor_alive: bool) -> str:
    """Disambiguate a DAP request timeout (S15): the same timeout means
    different things depending on whether the editor is alive. Alive -> the
    game is paused/busy (the DAP request hung; `debugger continue` resumes
    it). Dead -> the editor is gone (run `restart`)."""
    if editor_alive:
        return ("DAP request hung (game paused/busy) — try `debugger continue`; "
                "editor is alive")
    return "editor dead — run `restart`"


def recover_plan(editor_alive: bool, game_running: bool, bridge_up: bool,
                 breaked: bool, orphan_pid: int) -> dict:
    """Pure recovery decision (S1): given the current process/bridge state,
    return which recovery action to take. Consumed by client.recover() (B2).

    Precedence: editor down > orphan > game-up-but-bridge-down > breaked > ok.
    `orphan_pid == 0` means no orphan.
    """
    if not editor_alive:
        return {"action": "relaunch_editor"}
    if orphan_pid:
        return {"action": "kill_orphan", "orphan_pid": orphan_pid}
    if game_running and not bridge_up:
        return {"action": "replay_scene"}
    if breaked:
        return {"action": "continue_breaked"}
    return {"action": "ok"}


def suite_marker(result) -> str:
    # TRUSTWORTHY only if the on-disk result is present AND green
    # (ok is not false AND fail == 0). The file is JSON, so `result` is the
    # parsed dict (or None when the file is absent / unreadable).
    if not isinstance(result, dict) or "fail" not in result:
        return "INCOMPLETE"
    if result.get("ok") is False:
        return "INCOMPLETE"
    if isinstance(result.get("fail"), int) and result["fail"] != 0:
        return "INCOMPLETE"
    return "TRUSTWORTHY"


# ---------------------------------------------------------------------------
# doctor — pure setup diagnosis
# ---------------------------------------------------------------------------

# Godot version floors (keep in sync with README requirements table and CI):
# core bridge features are CI-gated on 4.7; DAP commands need engine 4.8+.
DOCTOR_MIN_GODOT = (4, 7)
DOCTOR_DAP_GODOT = (4, 8)


def _parse_ver(s):
    """'4.7' / '4.8.dev' -> (4, 7); anything unparseable -> None."""
    try:
        parts = str(s).strip().split(".")
        return (int(parts[0]), int(parts[1]))
    except (ValueError, IndexError):
        return None


def doctor_evaluate(project_exists, features, autoload_lines, plugin_lines,
                    python_version, godot_version_out, heartbeat_age_s,
                    os_name, heartbeat_stale_s=2.0):
    """Diagnose a bridge install from static facts only (no live editor).

    Returns a list of Check dicts: {name, status: ok|fail|warn, detail, fix}.
    `fix` is None for passing checks. Exit code policy lives in the CLI:
    0 iff no check has status 'fail'.

    Pure: all inputs are plain values so this is fully unit-testable.
    """
    checks = []

    def add(name, status, detail, fix=None):
        checks.append({"name": name, "status": status, "detail": detail,
                       "fix": fix})

    if not project_exists:
        add("project_godot", "fail",
            "no project.godot in this directory",
            "Run the doctor from your Godot project root (the directory "
            "containing project.godot), or pass --path /to/your/project.")
        return checks
    add("project_godot", "ok", "project.godot found")

    # Godot feature floor (README: 4.7+ core, 4.8+ for DAP commands).
    ver = _parse_ver(features)
    if ver is None:
        add("godot_features", "warn",
            "could not read config/features from project.godot",
            "Open the project once in Godot 4.7+ so project.godot is saved.")
    elif ver < DOCTOR_MIN_GODOT:
        add("godot_features", "fail",
            "project features say Godot %d.%d — below the supported floor"
            % ver,
            "Open and save the project with Godot >= %d.%d (see README "
            "Requirements)." % DOCTOR_MIN_GODOT)
    elif ver < DOCTOR_DAP_GODOT:
        add("godot_features", "warn",
            "Godot %d.%d project: core bridge works, but `debugger ...` "
            "commands need the 4.8+ engine DAP server" % ver,
            "For DAP commands, open the project with Godot >= 4.8.")
    else:
        add("godot_features", "ok", "Godot %d.%d+ features" % ver)

    # Python floor (bridge/cli is stdlib-only, >= 3.9).
    if tuple(python_version) < (3, 9):
        add("python_version", "fail",
            "Python %s < 3.9" % ".".join(str(p) for p in python_version),
            "Run the CLI with Python 3.9+ (e.g. `python3.11 bridge/cli/"
            "editor_bridge_cli.py ...`); CI is tested on 3.11/3.12.")
    else:
        add("python_version", "ok",
            "Python %s" % ".".join(str(p) for p in python_version))

    # Godot binary discovery (needed for `launch`/`restart`).
    if godot_version_out is None:
        add("godot_binary", "fail",
            "no Godot binary found (launch/restart would not work)",
            "Set GODOT_EDITOR_BINARY, or write the binary path to a "
            ".godot-editor-path file in your project root, or put godot on "
            "PATH (see CONTRIBUTING dev setup).")
    else:
        add("godot_binary", "ok", "Godot binary answers: %s"
            % str(godot_version_out).strip())

    # Autoload registration — anchored match: a near-name
    # (MyDebugBridge=) or a commented line (already filtered upstream in
    # the reader) must NOT read as registered.
    registered = any(re.match(r"\s*DebugBridge\s*=", line)
                     for line in autoload_lines)
    if registered:
        add("autoload_debug_bridge", "ok", "DebugBridge autoload registered")
    else:
        add("autoload_debug_bridge", "fail",
            "DebugBridge autoload missing from project.godot [autoload]",
            "Add to project.godot [autoload]: "
            'DebugBridge="*res://bridge/autoloads/debug_bridge.gd"')

    # Editor plugins (both must be enabled). Comment lines are filtered
    # defensively (the CLI reader strips them too): a commented-out
    # registration is NOT registered.
    plugins_blob = "\n".join(l for l in plugin_lines
                             if not l.strip().startswith(";"))
    needed = ["res://bridge/editor_bridge/plugin.cfg",
              "res://bridge/human_edit/plugin.cfg"]
    missing = [p for p in needed if p not in plugins_blob]
    if not missing:
        add("editor_plugins", "ok", "both editor plugins enabled")
    else:
        add("editor_plugins", "fail",
            "missing plugin entries: %s" % ", ".join(missing),
            "Set in project.godot: enabled=PackedStringArray("
            '"res://bridge/editor_bridge/plugin.cfg", '
            '"res://bridge/human_edit/plugin.cfg") '
            "(or enable Editor Bridge + HumanEdit under "
            "Project Settings -> Plugins)")

    # Editor liveness — warn only: the doctor works with no editor running.
    if heartbeat_age_s is None:
        add("editor_heartbeat", "warn",
            "no editor heartbeat (state.json missing) — editor not running?",
            "Start the editor through the CLI: `... editor_bridge_cli.py "
            "launch` (this is fine if you only wanted a setup check).")
    elif heartbeat_age_s > heartbeat_stale_s:
        add("editor_heartbeat", "warn",
            "editor heartbeat stale (%.1fs old) — editor closed or busy?"
            % heartbeat_age_s,
            "Check `query state`; then `recover` once, or `launch` a fresh "
            "editor.")
    else:
        add("editor_heartbeat", "ok",
            "editor heartbeat fresh (%.1fs)" % heartbeat_age_s)

    # OS support statement (macOS untested).
    if os_name == "Darwin":
        add("os_support", "warn",
            "macOS is not an officially supported platform (untested)",
            "It generally works — but file issues with details, and expect "
            "Linux/Windows to be validated first.")
    else:
        add("os_support", "ok", "%s is supported" % os_name)

    return checks
