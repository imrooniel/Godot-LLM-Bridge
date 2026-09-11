#!/usr/bin/env python3
"""Editor Bridge CLI — file-mailbox bridge to the Godot editor.

Transport: JSON request/response FILES under .tmp/bridge/ — no sockets in
the editor, so no half-open connections, no leaked ports, crash-proof and
parallel by construction.

    .tmp/bridge/inbox/<id>.json        CLI -> editor requests
    .tmp/bridge/outbox/<id>.json       editor -> CLI responses
    .tmp/bridge/events/<client>.jsonl  streaming events (subscribers)
    .tmp/bridge/state.json             editor heartbeat + full state (250 ms)

Liveness is measured: state.json carries a heartbeat; a heartbeat older
than 2 s means the editor is dead (no stale "connected" state possible).

The CLI is the ONLY way to start the Godot editor from the command line
(a second editor instance breaks the single source of truth).

Usage:
    python3 bridge/cli/editor_bridge_cli.py launch                 # start editor
    python3 bridge/cli/editor_bridge_cli.py ping                   # liveness
    python3 bridge/cli/editor_bridge_cli.py query state            # full state
    python3 bridge/cli/editor_bridge_cli.py action scene-open res://scenes/combat.tscn
    python3 bridge/cli/editor_bridge_cli.py action scene-play --path res://scenes/combat.tscn
    python3 bridge/cli/editor_bridge_cli.py action scene-stop
    python3 bridge/cli/editor_bridge_cli.py subscribe listen       # stream events
    python3 bridge/cli/editor_bridge_cli.py logs get --source auto
    python3 bridge/cli/editor_bridge_cli.py game ping              # editor + game
"""

import argparse
import configparser
import glob
import json
import os
import platform
import subprocess
import sys
import time
import uuid

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BRIDGE_DIR = os.path.join(PROJECT_ROOT, ".tmp", "bridge")
INBOX_DIR = os.path.join(BRIDGE_DIR, "inbox")
OUTBOX_DIR = os.path.join(BRIDGE_DIR, "outbox")
EVENTS_DIR = os.path.join(BRIDGE_DIR, "events")
STATE_FILE = os.path.join(BRIDGE_DIR, "state.json")
CONSOLE_LOG = os.path.join(PROJECT_ROOT, ".tmp", "logs", "editor-console.log")
LAUNCH_MARKER_PREFIX = "=== EditorBridge launch"

DEFAULT_TIMEOUT = 30.0
LIVE_WINDOW_S = 2.0      # heartbeat younger than this = editor alive
LAUNCH_DEADLINE_S = 300.0  # first run after an engine upgrade reimports everything
BINARY_CONFIG = os.path.join(PROJECT_ROOT, ".godot-editor-path")


def rel(p: str) -> str:
    """Display path relative to the project root; absolute if outside it.

    Keeps CLI output and any captured logs machine/repo-location agnostic
    (dogfood BD-003: absolute paths leaked /home/<user> into tracked state).
    """
    try:
        rp = os.path.relpath(p, PROJECT_ROOT)
    except ValueError:
        return p
    return rp if not rp.startswith(os.pardir) else p


class EditorBridgeError(Exception):
    """Raised on bridge/rpc errors (editor responded with an error, or timeout)."""


class EditorBridgeNotRunning(Exception):
    """Raised when the editor has no fresh heartbeat."""


def _find_godot_binary():
    """Find the Godot 4.x editor binary. Returns None if not found.

    Order: GODOT_EDITOR_BINARY env var → project-local .godot-editor-path
    (one line, absolute or relative to the project root — the recommended
    setup for custom builds; machine-local, keep it out of git) → PATH →
    registry → common install locations.
    """
    env = os.environ.get("GODOT_EDITOR_BINARY")
    if env and os.path.exists(env):
        return env

    try:
        with open(BINARY_CONFIG) as f:
            cfg = f.read().strip().strip('"').strip("'")
        if cfg:
            cfg = cfg if os.path.isabs(cfg) else os.path.join(PROJECT_ROOT, cfg)
            if os.path.exists(cfg):
                return cfg
            print("Warning: %s points to a missing binary: %s (falling back to "
                  "auto-detection)" % (BINARY_CONFIG, cfg), file=sys.stderr)
    except FileNotFoundError:
        pass
    except OSError as e:
        print("Warning: cannot read %s: %s" % (BINARY_CONFIG, e), file=sys.stderr)

    import shutil
    for name in ("godot", "godot4", "Godot", "godot-editor"):
        found = shutil.which(name)
        if found:
            return found

    system = platform.system()
    if system == "Windows":
        try:
            import winreg
            key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"SOFTWARE\Godot")
            for i in range(100):
                try:
                    path, _, _ = winreg.EnumValue(key, i)
                    if "Godot_v" in path and ".exe" in path:
                        return path
                except EnvironmentError:
                    break
                winreg.CloseKey(key)
        except Exception:
            pass
        common = [
            r"C:\Program Files\Godot\Godot_v4.*.exe",
            os.path.expandvars(r"%LOCALAPPDATA%\Programs\Godot\Godot.exe"),
            os.path.expandvars(r"%USERPROFILE%\AppData\Local\Godot\app_release\Godot.exe"),
        ]
    elif system == "Darwin":
        common = [
            "/Applications/Godot.app/Contents/MacOS/Godot",
            "/opt/local/bin/Godot",
        ]
    else:
        # Patterns may match the binary itself OR a directory containing it
        # (e.g. /opt/Godot_v4.6.1-stable_mono_linux_x86_64/).
        common = [
            "/opt/Godot_v4*",
            "/usr/local/bin/Godot*",
            os.path.expanduser("~/Godot/Godot_v4*"),
            os.path.expanduser("~/.local/bin/godot*"),
        ]

    for pattern in common:
        for match in sorted(glob.glob(pattern)):
            if os.path.isdir(match):
                for entry in sorted(os.listdir(match), reverse=True):
                    full = os.path.join(match, entry)
                    if os.path.isfile(full) and os.access(full, os.X_OK):
                        return full
            elif os.path.isfile(match) and os.access(match, os.X_OK):
                return match
    return None


def _atomic_write(path, data: dict) -> None:
    tmp = "%s.tmp-%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def _parse_value(value: str):
    """Try to parse a string value as JSON, fall back to string."""
    try:
        return json.loads(value)
    except (json.JSONDecodeError, ValueError):
        return value


def _resolved_path(args) -> str:
    """Path supplied as a positional and/or --path (both spellings accepted)."""
    pos = getattr(args, "path_pos", None)
    flag = getattr(args, "path", None)
    if pos and flag and pos != flag:
        raise SystemExit("path given twice (positional vs --path): %r vs %r"
                         % (pos, flag))
    resolved = pos or flag or ""
    if not resolved:
        raise SystemExit("a scene path is required (positional or --path)")
    return resolved


def _parse_json_params(raw: str) -> dict:
    """Parse a --json-params value into a dict. Empty/None -> {}."""
    if raw is None or raw.strip() == "":
        return {}
    try:
        val = json.loads(raw)
    except json.JSONDecodeError as e:
        raise SystemExit(f"--json-params is not valid JSON: {e}")
    if not isinstance(val, dict):
        raise SystemExit("--json-params must be a JSON object ({...})")
    return val


_GLOBAL_CLIENT = None


def _contract_ok(result: dict, state: dict) -> dict:
    return {"ok": True, "state": state, "result": result}


def _contract_err(result_or_err: dict, state: dict, reason: str, suggested=None) -> dict:
    # result_or_err is the editor's payload; promote its `error` if present, else wrap.
    err = result_or_err.get("error") if isinstance(result_or_err, dict) else None
    if not isinstance(err, dict):
        err = {"code": -32000, "message": str(result_or_err)}
    err.setdefault("reason", reason)
    err.setdefault("suggested", suggested or [])
    return {"ok": False, "state": state, "error": err}


def _current_state(state: dict = None) -> dict:
    """Small {game, breaked, turn} state object from a heartbeat dict (no round trip)."""
    if state is None:
        client = _GLOBAL_CLIENT
        state = (client.read_state() if client else None) or {}
    g = state.get("game", {}) or {}
    dbg = state.get("debugger", {}) or {}
    return {
        "game": "running" if g.get("running") else "stopped",
        "breaked": bool(dbg.get("breaked")),
        "turn": "",  # the bridge cannot know the LLM's turn; see spec §3 / Task 6 doc
    }


class EditorBridgeClient:
    """File-mailbox client. Every call is self-contained (no persistent
    connection to manage) — parallel invocations are safe by construction."""

    def __init__(self):
        for d in (BRIDGE_DIR, INBOX_DIR, OUTBOX_DIR, EVENTS_DIR):
            os.makedirs(d, exist_ok=True)

    # --- liveness ---------------------------------------------------------

    def read_state(self):
        """Last heartbeat from state.json (no round trip). None if absent."""
        try:
            with open(STATE_FILE) as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError):
            return None
        age = time.time() - data.get("heartbeat_ms", 0) / 1000.0
        data["alive"] = bool(data.get("alive")) and age < LIVE_WINDOW_S
        data["heartbeat_age_s"] = round(max(age, 0.0), 2)
        return data

    def read_state_retry(self, attempts: int = 6, interval_s: float = 0.05):
        """read_state() that tolerates a racy/partial state.json read.

        The editor rewrites state.json atomically every ~250 ms; a single open()
        can land mid-rename and hit a JSONDecodeError (-> None). On the failure
        path (a game command just timed out) we specifically need a trustworthy
        state, so retry a few times before giving up.
        """
        state = None
        for _ in range(max(1, attempts)):
            state = self.read_state()
            if state:
                return state
            time.sleep(interval_s)
        return state

    def ping(self):
        # read_state_retry, not read_state: the editor rewrites state.json
        # every ~250 ms (tmp + rename) and a single open() can land mid-rename
        # (Windows sharing violation -> OSError -> None). A transient read
        # miss is NOT a dead editor — retry the read before declaring it so.
        state = self.read_state_retry()
        if not state or not state.get("alive"):
            raise EditorBridgeNotRunning(
                "editor not reachable (no fresh heartbeat in %s)" % rel(STATE_FILE))
        return state

    # --- rpc --------------------------------------------------------------

    def rpc(self, cmd: str, args: dict = None, timeout: float = DEFAULT_TIMEOUT) -> dict:
        """Send a request, wait for the response file. Returns result fields."""
        req_id = uuid.uuid4().hex
        _atomic_write(os.path.join(INBOX_DIR, req_id + ".json"),
                      {"id": req_id, "cmd": cmd, "args": args or {}, "timeout": timeout})
        out_path = os.path.join(OUTBOX_DIR, req_id + ".json")
        deadline = time.time() + timeout
        unreadable = 0
        while time.time() < deadline:
            if os.path.exists(out_path):
                data = None
                try:
                    with open(out_path) as f:
                        data = json.load(f)
                except (OSError, ValueError):
                    # The editor writes responses with a tmp file + rename;
                    # on Windows an open() landing inside the replace window
                    # hits a transient sharing violation (PermissionError) or
                    # a partial read. The request WAS processed — retry the
                    # READ, never re-send, and never delete an unreadable
                    # response (that would destroy a successful result; the
                    # editor's orphan purge cleans leftovers).
                    unreadable += 1
                    time.sleep(0.05)
                    continue
                try:
                    os.unlink(out_path)
                except OSError:
                    pass  # readable; a failed unlink is harmless (orphan purge)
                if not data.get("ok"):
                    err = data.get("error", {})
                    raise EditorBridgeError("%s: %s" % (cmd, err.get("message", err)))
                return {k: v for k, v in data.items() if k not in ("id", "ok")}
            time.sleep(0.02)
        raise EditorBridgeError(
            "%s: timed out after %.0fs (is the editor alive? try 'ping')%s"
            % (cmd, timeout,
               " — response file appeared but was never readable (%d attempts)"
               % unreadable if unreadable else ""))

    # --- launch -----------------------------------------------------------

    def launch(self, project_path=None) -> dict:
        """Launch the Godot editor and wait for a fresh heartbeat.

        Editor stdout/stderr are captured to .tmp/logs/editor-console.log —
        the ONLY record of pre-plugin-init output (startup parse errors).
        A marker line with the editor pid separates each launch.
        """
        binary = _find_godot_binary()
        if not binary:
            print("Error: Godot binary not found.", file=sys.stderr)
            print("Set GODOT_EDITOR_BINARY env var, write the binary path to %s,"
                  " or install Godot 4.x." % BINARY_CONFIG, file=sys.stderr)
            sys.exit(1)

        cmd = [binary, "--editor", "--path", project_path or PROJECT_ROOT]
        print("Launching: %s --editor --path %s"
              % (binary, rel(project_path or PROJECT_ROOT)), file=sys.stderr)

        log_dir = os.path.dirname(CONSOLE_LOG)
        os.makedirs(log_dir, exist_ok=True)
        log_file = open(CONSOLE_LOG, "ab", buffering=0)
        proc = subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)
        try:
            log_file.write(("\n%s %s (editor pid %d) ===\n"
                            % (LAUNCH_MARKER_PREFIX, time.strftime("%Y-%m-%d %H:%M:%S"),
                               proc.pid)).encode("utf-8"))
        except OSError:
            pass
        print("Editor console: %s" % rel(CONSOLE_LOG), file=sys.stderr)

        # Editor startup can take ~45 s on first import.
        deadline = time.time() + LAUNCH_DEADLINE_S
        while time.time() < deadline:
            if proc.poll() is not None:
                print("Error: editor process exited early (code %s)" % proc.returncode,
                      file=sys.stderr)
                self._print_console_tail(15)
                sys.exit(1)
            state = self.read_state()
            if state and state.get("alive"):
                print("EditorBridge ready! (editor pid %d)"
                      % state.get("editor", {}).get("pid", 0),
                      file=sys.stderr)
                return state
            time.sleep(0.5)

        print("Error: editor did not become ready within %.0fs" % LAUNCH_DEADLINE_S,
              file=sys.stderr)
        print("Tail of editor console:", file=sys.stderr)
        self._print_console_tail(20)
        sys.exit(1)

    def _print_console_tail(self, n: int) -> None:
        try:
            with open(CONSOLE_LOG) as f:
                lines = f.readlines()
            sys.stderr.write("".join(lines[-n:]))
        except OSError:
            pass

    # --- restart ----------------------------------------------------------

    def restart(self, project_path=None) -> dict:
        """CLI-owned editor restart: quit, wait for death, launch.

        Never trust the engine's own restart (EditorInterface.restart_editor
        = save + quit, and the relaunch is a best-effort spawn whose failure
        is silently dropped — main.cpp:5327 ignores create_instance's Error):
        the editor can stay dead with no trace. Here the CLI remains the one
        thing that ever starts the editor (the launch contract).
        """
        state = self.read_state()
        if state and state.get("alive"):
            print("Asking the editor to quit...", file=sys.stderr)
            try:
                self.rpc("action.editor.close", {}, timeout=10)
            except (EditorBridgeError, EditorBridgeNotRunning) as e:
                print("close request not acknowledged (%s) — waiting anyway" % e,
                      file=sys.stderr)
            deadline = time.time() + 30.0
            while time.time() < deadline:
                st = self.read_state()
                if not st or not st.get("alive"):
                    break
                time.sleep(0.25)
            else:
                print("Error: editor still alive 30s after the quit request — a "
                      "modal dialog (unsaved scene / running project) is likely "
                      "blocking shutdown. Inspect with `query dialogs` and "
                      "`action dialog-accept`, then retry.", file=sys.stderr)
                sys.exit(1)
            print("Editor stopped.", file=sys.stderr)
        else:
            print("Editor not running — launching directly.", file=sys.stderr)
        return self.launch(project_path)

    # --- subscribe / listen -----------------------------------------------

    def listen(self, events=None, state=False) -> None:
        """Subscribe and stream events until Ctrl+C."""
        client_id = uuid.uuid4().hex[:12]
        result = self.rpc("subscribe",
                          {"client_id": client_id, "events": events or [], "state": state},
                          timeout=10)
        what = ", ".join(result.get("events", [])) or "(none)"
        if state:
            what += " + state"
        print("Listening as %s (events: %s) — Ctrl+C to stop" % (client_id, what),
              file=sys.stderr)
        event_file = os.path.join(EVENTS_DIR, client_id + ".jsonl")
        offset = 0
        try:
            while True:
                if os.path.exists(event_file):
                    with open(event_file, "rb") as f:
                        f.seek(offset)
                        chunk = f.read()
                    if chunk:
                        nl = chunk.rfind(b"\n")
                        if nl >= 0:  # only consume complete lines
                            complete = chunk[:nl + 1]
                            offset += len(complete)
                            for line in complete.decode("utf-8", "replace").splitlines():
                                if not line.strip():
                                    continue
                                try:
                                    msg = json.loads(line)
                                except json.JSONDecodeError:
                                    continue
                                print("[%s] %s: %s" % (
                                    time.strftime("%H:%M:%S"),
                                    msg.get("event", "?"),
                                    json.dumps(msg.get("data", {}), default=str)),
                                    flush=True)
                time.sleep(0.1)
        except KeyboardInterrupt:
            pass
        finally:
            try:
                self.rpc("unsubscribe", {"client_id": client_id}, timeout=2)
            except EditorBridgeError:
                pass


def _project_user_dir() -> str:
    """Local directory behind user:// (for screenshot resolution)."""
    name = "project"
    try:
        cp = configparser.ConfigParser()
        cp.read(os.path.join(PROJECT_ROOT, "project.godot"))
        name = cp.get("application", "config/name", fallback="project")
    except (OSError, configparser.Error):
        pass
    base = os.path.expanduser(
        "~/.local/share/godot/app_userdata" if platform.system() != "Windows"
        else "~/AppData/Roaming/godot/app_userdata")
    return os.path.join(base, name)


def _resolve_user_path(path: str) -> str:
    if path and path.startswith("user://"):
        return os.path.join(_project_user_dir(), path[len("user://"):])
    return path


def _print_game_unreachable(err: "EditorBridgeError") -> None:
    """When a game command can't reach the DebugBridge, report WHY — seamlessly.

    The in-game DebugBridge (127.0.0.1:5555) only answers while the game is
    running AND unpaused. When it's unreachable we read the editor's own view of
    the game state (state.json) and branch:

      * process exited   -> crash report (re-run scene-play, read panel logs).
      * paused at a break/exception (debugger.breaked == True) -> the game is
        frozen, which is why the 5555 bridge is silent. We investigate INLINE:
        auto-attach to the DAP session, fetch the stack + pause reason + a tail
        of the DAP output, and print it all here. The caller needs no extra
        commands to see the error.
      * alive but not breaked -> bridge dropped / mid-restart.

    A single racy state.json read can't derail the report: we retry the read.
    Any auto-investigation step that fails degrades gracefully to the manual tips.
    """
    print("Error: %s" % err, file=sys.stderr)
    state = {}
    client = None
    try:
        client = EditorBridgeClient()
        state = client.read_state_retry() or {}
    except Exception:
        state = {}
    game = state.get("game", {}) if isinstance(state, dict) else {}
    running = game.get("running")
    scene = game.get("playing_scene")
    dbg = state.get("debugger", {}) if isinstance(state, dict) else {}
    breaked = dbg.get("breaked")

    print("\n--- game bridge unreachable; editor view ---", file=sys.stderr)
    print("  game_running:      %s" % running, file=sys.stderr)
    print("  playing_scene:     %s" % scene, file=sys.stderr)
    print("  debugger_breaked:  %s" % breaked, file=sys.stderr)

    if not running:
        print(
            "  => the game PROCESS EXITED. It likely crashed. Re-run with "
            "`action scene-play` and check `logs get --source panel` "
            "or the editor console for the crash error.", file=sys.stderr)
        _print_debugger_tip()
        return

    if breaked:
        _report_paused_game(client, state)
        return

    print(
        "  => the game process is alive but its DebugBridge dropped and it is "
        "NOT paused (breaked=False). It may be mid-restart; retry in a few "
        "seconds, or `action scene-stop` then `action scene-play`.", file=sys.stderr)
    _print_debugger_tip()


# Signatures of GENUINE transport failures on the game command path.
# Anything else is a structured JSON-RPC error the editor returned (a logic
# error — the game was never touched), and must be printed plainly instead of
# the "game bridge unreachable" diagnostic (dogfood BD-006).
_TRANSPORT_MARKERS = (
    "unreachable",                     # editor-side: bridge not reachable (start failed)
    "timed out",                       # editor-side timeout AND in-game proxy timeout
    "disconnected mid-request",        # in-game proxy: socket dropped while pending
)


def _is_game_transport_failure(err: "EditorBridgeError") -> bool:
    """True iff a game-command error is a genuine transport failure (timeout /
    disconnect / bridge never reachable), as opposed to a structured error the
    editor answered with (policy rejection, bad node path, method-not-found, a
    compile check failure, ...). In the logic-error case the game was never
    touched, so the "game bridge unreachable; editor view" diagnostic is
    misleading and must be suppressed.

    Message-based by design: the file-mailbox transport carries only a text
    message, and every transport path (editor-side `_proxy_game` unreachable,
    in-game `game_proxy` timeout/disconnect, and the CLI's own poll deadline)
    is covered by the markers above, while no legitimate editor-returned logic
    error text contains them.
    """
    msg = str(err)
    return any(marker in msg for marker in _TRANSPORT_MARKERS)


def _handle_game_error(err: "EditorBridgeError") -> None:
    """Report a game-command error, then exit(1).

    Real transport failures (timeout / disconnect / bridge never reachable) get
    the full unreachable-investigation (crash report / paused-stack / alive-but-
    dropped). Structured errors the editor answered with (logic errors: policy
    rejection, bad node path, method-not-found, compile check failure) are
    printed plainly — the game was never touched, so the "game bridge
    unreachable" diagnostic would mislead.
    """
    if _is_game_transport_failure(err):
        _print_game_unreachable(err)
    else:
        # Logic error: the editor answered cleanly; the in-game bridge was never
        # touched. Show the editor's message as-is (no unreachable block).
        print("Error: %s" % err, file=sys.stderr)
    # Legibility contract to STDOUT (machine-readable); the human-readable
    # investigation above stays on stderr. reason is the actionable signal
    # (spec §6) — the LLM acts on reason+suggested, not a timeout.
    _st = _current_state() if _GLOBAL_CLIENT else \
        {"game": "stopped", "breaked": False, "turn": ""}
    if "write deferred" in str(err):
        # Coordinator defer (Task 5, spec §4.3): a game WRITE while the game is
        # DAP-breaked was refused up front (reason game_paused). The editor's
        # structured reason/suggested is the right signal — don't downgrade it
        # to a generic logic_error.
        _reason = "game_paused"
        _suggested = ["debugger continue", "retry this write after the game resumes"]
    elif _is_game_transport_failure(err):
        # Transport failure: reason distinguishes paused vs dead.
        _reason = "game_paused" if _st.get("breaked") else "game_not_running"
        _suggested = (["debugger continue", "retry the command after the game resumes"]
                      if _reason == "game_paused"
                      else ["action scene-play (start the game)", "query godot-status (re-check)"])
    else:
        # Logic error: the editor answered cleanly and the game was never
        # touched — a game hint (scene-play/debugger continue) would mislead.
        _reason = "logic_error"
        _suggested = ["read error.message and adjust the request", "query godot-status (re-check)"]
    try:
        print(json.dumps(_contract_err({"message": str(err)}, _st, _reason, _suggested),
                         indent=2))
    except Exception:
        pass
    sys.exit(1)


def _print_debugger_tip() -> None:
    print("  Tip: `debugger state` shows DAP state; `logs get --source panel` "
          "has the editor console.", file=sys.stderr)


def _report_paused_game(client, state: dict) -> None:
    """Game is paused at a break/exception. Investigate inline via DAP.

    The 5555 in-game bridge is silent because the game loop is frozen, but the
    editor's DAP session can still read the paused stack. We auto-attach, fetch
    the stack + pause reason + a log tail, and print them so the caller sees the
    error without issuing separate debugger commands.
    """
    print(
        "  => the game is ALIVE but PAUSED (a runtime break/exception froze it; "
        "that's why the 5555 bridge is silent). Investigating via DAP...",
        file=sys.stderr)

    dbg = state.get("debugger", {}) if isinstance(state, dict) else {}
    last_stopped = dbg.get("last_stopped") or {}
    if last_stopped:
        reason = last_stopped.get("reason", "")
        text = last_stopped.get("text", "")
        line = "  pause reason:      %s" % reason
        if text:
            line += "  —  %s" % text
        print(line, file=sys.stderr)

    if client is None:
        try:
            client = EditorBridgeClient()
        except Exception:
            client = None

    # 1) Auto-attach (no-op if already attached).
    attached = dbg.get("attached")
    try:
        if not attached:
            client.rpc("action.debugger.attach", {}, timeout=15)
            print("  [auto] attached to the DAP session.", file=sys.stderr)
    except Exception as e:
        print("  [auto] attach failed: %s" % e, file=sys.stderr)

    # 2) Fetch the stack (async on the engine side; the bridge waits for the dump).
    frames = []
    try:
        resp = client.rpc("query.debugger.stack", {}, timeout=30)
        frames = resp.get("stackFrames", []) if isinstance(resp, dict) else []
    except Exception as e:
        print("  [auto] stack fetch failed: %s" % e, file=sys.stderr)
    if frames:
        print("\n  --- paused stack (top frame first) ---", file=sys.stderr)
        for i, fr in enumerate(frames[:25]):
            src = fr.get("source", {}) or {}
            name = src.get("name", "?")
            path = src.get("path", "")
            line_no = int(fr.get("line", 0)) if fr.get("line") is not None else 0
            func = fr.get("name", "")
            prefix = "  > " if i == 0 else "    "
            print("%s%s:%d  in %s" % (prefix, name, line_no, func), file=sys.stderr)
            if path and i == 0:
                print("%s    %s" % ("    ", path), file=sys.stderr)

    # 3) Tail of the DAP output (game console + error context).
    try:
        resp = client.rpc("query.debugger.output", {"max_lines": 40}, timeout=15)
        lines = resp.get("messages", []) if isinstance(resp, dict) else []
        if lines:
            print("\n  --- last %d DAP output lines (game console) ---"
                  % len(lines), file=sys.stderr)
            for ln in lines:
                print("  | %s" % str(ln).replace("\n", " ⏎ "), file=sys.stderr)
    except Exception as e:
        print("  [auto] output fetch failed: %s" % e, file=sys.stderr)

    print("\n  To investigate:  `debugger vars` / `debugger eval '<expr>'` / "
          "`debugger step-over`", file=sys.stderr)
    print("  To resume the game:  `debugger continue`   (or `action scene-stop`)",
          file=sys.stderr)
    if client is not None:
        try:
            client.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Command surface
# ---------------------------------------------------------------------------

GAME_COMMANDS = {
    # cli subcommand: (game bridge method, params builder)
    "ping":            ("ping", lambda a: {}),
    "inspect-tree":    ("inspect_tree", lambda a: {"path": a.path, "depth": a.depth}),
    "get":             ("get_property", lambda a: {"path": a.path, "prop": a.prop}),
    "set":             ("set_property", lambda a: {"path": a.path, "prop": a.prop,
                                                   "value": _parse_value(a.value)}),
    "signal":          ("emit_signal", lambda a: {"path": a.path, "signal": a.signal_name,
                                                  "args": [_parse_value(x) for x in a.args]}),
    "call":            ("call_method", lambda a: {"path": a.path, "method": a.method_name,
                                                  "args": [_parse_value(x) for x in a.args]}),
    "signals":         ("list_signals", lambda a: {"path": a.path}),
    "methods":         ("list_methods", lambda a: {"path": a.path, "pattern": a.pattern}),
    "scene-info":      ("get_scene_info", lambda a: {}),
    "scan-ui":         ("scan_ui", lambda a: {"root": a.root, "types": a.types or []}),
    "find-nodes":      ("find_nodes", lambda a: {"root": a.root,
                                                 "name_pattern": a.name_pattern,
                                                 "type": a.type or "",
                                                 "recursive": not a.no_recursive,
                                                 "owned": a.owned}),
    "inspect-control": ("inspect_control", lambda a: {"path": a.path}),
    "screenshot":      ("screenshot", lambda a: {"path": a.path, "wait_ms": a.wait_ms}),
    "screenshot-b64":  ("screenshot_base64", lambda a: {"scale": a.scale,
                                                        "wait_ms": a.wait_ms}),
    "game-status":     ("game_status", lambda a: {}),
    # Closed-loop driving (ported from community v2.3): held input + batch read +
    # per-frame telemetry.
    "hold":            ("hold_key", lambda a: {"key": a.key_name}),
    "release":         ("release_key", lambda a: {"key": a.key_name}),
    "held-keys":       ("held_keys", lambda a: {}),
    "get-many":        ("batch_get", lambda a: {
        "items": [{"path": p, "prop": pr} for p, pr in zip(a.paths, a.props)]}),
    "watch":           ("telemetry_start", lambda a: {
        "hz": a.hz,
        "nodes": [{"path": p, "props": _parse_value(pr)}
                  for p, pr in zip(a.nodes, a.props)]}),
    "sample":          ("telemetry_sample", lambda a: {"limit": a.limit}),
    "telemetry-stop":  ("telemetry_stop", lambda a: {}),
    "lua-eval":        ("execute_lua", lambda a: {"code": a.code}),
    "gd-eval":         ("gd_eval", lambda a: {"expression": a.expression}),
    "eval":            ("gd_eval", lambda a: {"expression": a.expression}),
    "api-class":       ("api_class", lambda a: {"class": a.class_name,
                                                "filter": a.filter or ""}),
    "reload-script":   ("reload_script", lambda a: {"path": a.path}),
    "logs":            ("get_godot_logs", lambda a: {"from": a.from_line,
                                                     "max_lines": a.max_lines}),
    "key":             ("inject_key", lambda a: {"key": a.key_name,
                                                 "pressed": not a.release}),
    "mouse":           ("inject_mouse", lambda a: {"action": a.action, "x": a.x, "y": a.y,
                                                   "button": a.button,
                                                   "unhandled": a.unhandled}),
    "click-node":      ("click_node", lambda a: {"path": a.path, "button": a.button}),
    "time-scale":      ("set_time_scale", lambda a: {"scale": a.scale}),
    "change-scene":    ("change_scene", lambda a: {"path": a.path}),
    "quit":            ("graceful_quit", lambda a: {}),
    "clear-logs":      ("clear_godot_logs", lambda a: {}),
    "crashes":         ("get_crashes", lambda a: {"max_lines": a.max_lines}),
    "clear-crashes":   ("clear_crashes", lambda a: {}),
}

# Game requests that can legitimately take longer.
SLOW_GAME_OP_TIMEOUT = 120.0
GAME_TIMEOUTS = {"lua-eval": SLOW_GAME_OP_TIMEOUT,
                 "gd-eval": SLOW_GAME_OP_TIMEOUT, "eval": SLOW_GAME_OP_TIMEOUT,
                 "screenshot": 30.0, "screenshot-b64": 30.0,
                 "watch": SLOW_GAME_OP_TIMEOUT, "sample": SLOW_GAME_OP_TIMEOUT,
                 "get-many": SLOW_GAME_OP_TIMEOUT}

# Idempotent read-only game commands eligible for bounded retry on a transient
# bridge drop (the game bridge is single-client and a request can be lost mid
# scene-swap). Mutations (set/call/hold/release/inject_*) are deliberately
# EXCLUDED — blind-retrying them could double-apply. Ported from community v2.3.
RETRYABLE_GAME_COMMANDS = {
    "get", "get-many", "held-keys", "inspect-tree", "scan-ui", "find-nodes",
    "game-status", "sample", "screenshot", "screenshot-b64", "logs", "crashes",
    "api-class",
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Editor Bridge CLI for Godot (file mailbox)")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("launch", help="Start the editor and wait for it")
    subparsers.add_parser("restart",
                          help="Reliable restart: quit + wait + launch (preferred "
                               "over 'action editor-restart', which is the engine's "
                               "silent-failure quit+spawn)")
    subparsers.add_parser("ping", help="Check editor liveness (heartbeat)")
    subparsers.add_parser("connect", help="Verify the editor is reachable, print state")

    q = subparsers.add_parser("query")
    q_sub = q.add_subparsers(dest="query_type", required=True)
    q_sub.add_parser("state")
    q_sub.add_parser("editor")
    q_sub.add_parser("fs-scenes")
    q_sub.add_parser("autoloads")
    qs = q_sub.add_parser("scene")
    qs.add_argument("path")
    qs_tree = q_sub.add_parser("scene-tree")
    qs_tree.add_argument("path")
    qs_tree.add_argument("--depth", type=int, default=3)
    qfs = q_sub.add_parser("fs")
    qfs.add_argument("path")
    qfs_scripts = q_sub.add_parser("fs-scripts")
    qfs_scripts.add_argument("--path", default="res://")
    q_sub.add_parser("dialogs",
                     help="List visible editor dialogs (e.g. the 'reload from disk' popup)")
    q_sub.add_parser("godot-status",
                     help="The one call the LLM makes each turn: {ok, state{game,breaked,turn},"
                          " editor, game, debugger}. breaked is a state, never a timeout.")
    qhd = q_sub.add_parser("human-deltas",
                           help="Read buffered human editor edits (content deltas); --since <turn_id>")
    qhd.add_argument("--since", default="",
                     help="only deltas after this turn id (default: all buffered)")

    a = subparsers.add_parser("action")
    a_sub = a.add_subparsers(dest="action_type", required=True)
    asa = a_sub.add_parser("scene-open")
    asa.add_argument("path_pos", nargs="?", default=None, metavar="path")
    asa.add_argument("--path", default=None, help="alias for the positional path")
    ascl = a_sub.add_parser("scene-close")
    ascl.add_argument("path", nargs="?", default="")
    asv = a_sub.add_parser("scene-save")
    asv.add_argument("--path", default=None)
    a_sub.add_parser("scene-save-all")
    asp = a_sub.add_parser("scene-play")
    asp.add_argument("--path", default=None)
    a_sub.add_parser("scene-stop")
    asr = a_sub.add_parser("scene-reload")
    asr.add_argument("path_pos", nargs="?", default=None, metavar="path")
    asr.add_argument("--path", default=None, help="alias for the positional path")
    a_sub.add_parser("editor-restart")
    a_sub.add_parser("editor-close")
    a_sub.add_parser("scripts-reload")
    afs = a_sub.add_parser("fs-scan",
                           help="Rescan the editor filesystem — REQUIRED to register "
                                "new class_name scripts (scripts-reload cannot)")
    afs.add_argument("--wait", action="store_true",
                     help="Block until the scan finishes (polls query state)")
    asr1o = a_sub.add_parser("scripts-reload-one")
    asr1o.add_argument("path")
    asck = a_sub.add_parser(
        "scripts-check",
        help="Compile-check res:// scripts in the editor (edit -> scripts-check -> run-script loop; BD-013)")
    asck.add_argument("paths", nargs="+", help="one or more res://*.gd paths")
    aeval = a_sub.add_parser(
        "eval",
        help="Evaluate ONE GDScript expression in the EDITOR process "
             "(policy-checked: single expression, blacklist, no quit_editor)")
    aeval.add_argument("expression")
    ars = a_sub.add_parser(
        "run-script",
        help="Run a method of a repo .gd script in the EDITOR (BD-007 scene-"
             "generation channel; fresh from disk, git-reviewable code only)")
    ars.add_argument("path")
    ars.add_argument("method")
    ars.add_argument("args", nargs="*", help="string arguments passed to the method")
    ada = a_sub.add_parser("dialog-accept",
                           help="Click OK on a visible editor dialog whose OK button text matches")
    ada.add_argument("--ok-button", required=True,
                     help="Exact OK button text (e.g. 'Reload from disk')")

    g = subparsers.add_parser("game")
    g.add_argument("--no-retry", action="store_true",
                   help="Do not retry idempotent read commands on a transient bridge drop")
    g_sub = g.add_subparsers(dest="game_command", required=True)
    g_sub.add_parser("ping")
    gi = g_sub.add_parser("inspect-tree")
    gi.add_argument("path", nargs="?", default="root")
    gi.add_argument("--depth", type=int, default=1)
    gp = g_sub.add_parser("get")
    gp.add_argument("path")
    gp.add_argument("prop")
    gset = g_sub.add_parser("set")
    gset.add_argument("path")
    gset.add_argument("prop")
    gset.add_argument("value")
    gsig = g_sub.add_parser("signal")
    gsig.add_argument("path")
    gsig.add_argument("signal_name")
    gsig.add_argument("args", nargs="*")
    gcall = g_sub.add_parser("call")
    gcall.add_argument("path")
    gcall.add_argument("method_name")
    gcall.add_argument("args", nargs="*")
    gsub_sigs = g_sub.add_parser("signals")
    gsub_sigs.add_argument("path")
    gsub_meth = g_sub.add_parser("methods")
    gsub_meth.add_argument("path")
    gsub_meth.add_argument("--pattern", default="")
    g_sub.add_parser("scene-info")
    gscan = g_sub.add_parser("scan-ui")
    gscan.add_argument("--root", default="root")
    gscan.add_argument("--types", nargs="*")
    gfind = g_sub.add_parser("find-nodes")
    gfind.add_argument("--root", default="root")
    gfind.add_argument("--name-pattern", default="*")
    gfind.add_argument("--type", default="")
    gfind.add_argument("--recursive", action="store_true", default=True)
    gfind.add_argument("--no-recursive", action="store_true")
    gfind.add_argument("--owned", action="store_true")
    gic = g_sub.add_parser("inspect-control")
    gic.add_argument("path")
    gss = g_sub.add_parser("screenshot")
    gss.add_argument("path", nargs="?", default="user://debug_bridge_screenshot.png")
    gss.add_argument("--wait-ms", dest="wait_ms", type=int, default=0,
                     help="Settle N ms before capturing (the last rendered frame)")
    gssb64 = g_sub.add_parser("screenshot-b64")
    gssb64.add_argument("--scale", type=float, default=1.0)
    gssb64.add_argument("--wait-ms", dest="wait_ms", type=int, default=0,
                        help="Settle N ms before capturing (the last rendered frame)")
    g_sub.add_parser("game-status")
    glua = g_sub.add_parser("lua-eval")
    glua.add_argument("code")
    gdeval = g_sub.add_parser(
        "gd-eval",
        help="Evaluate one GDScript expression in the running game "
              "(autoloads/globals resolve; e.g. 'MyStateHub.party[0].hp')")
    gdeval.add_argument("expression")
    geval = g_sub.add_parser("eval", help="Alias of gd-eval")
    geval.add_argument("expression")
    gapic = g_sub.add_parser(
        "api-class",
        help="Introspect a class IN THIS Godot build (live ClassDB) — beats "
             "doc memory on dev builds (BD-009); --filter trims sections")
    gapic.add_argument("class_name", metavar="class")
    gapic.add_argument("--filter", default="",
                       help="case-insensitive substring for props/methods/signals/enums")
    grls = g_sub.add_parser(
        "reload-script",
        help="Hot-reload a res:// .gd into the running game's cache — edit a "
             "builder script, reload, call it again (no scene restart)")
    grls.add_argument("path")
    glogs = g_sub.add_parser("logs")
    glogs.add_argument("--from", dest="from_line", type=int, default=0)
    glogs.add_argument("--max-lines", type=int, default=5000)
    gkey = g_sub.add_parser("key")
    gkey.add_argument("key_name")
    gkey.add_argument("--release", action="store_true")
    # Closed-loop driving (ported from community v2.3).
    ghold = g_sub.add_parser(
        "hold",
        help="Hold a key: update the bridge held-set a polling controller reads "
             "via is_key_held/is_action_held, AND push the event")
    ghold.add_argument("key_name")
    grel = g_sub.add_parser("release", help="Release a previously held key")
    grel.add_argument("key_name")
    g_sub.add_parser("held-keys", help="List currently held keys/actions")
    ggetmany = g_sub.add_parser(
        "get-many", help="Read many (node, prop) pairs in one round-trip")
    ggetmany.add_argument("paths", nargs="+", help="Node path(s)")
    ggetmany.add_argument("--props", nargs="+", required=True,
                          help="Prop(s), parallel to paths")
    gwatch = g_sub.add_parser(
        "watch", help="Start per-frame telemetry sampling of node props")
    gwatch.add_argument("--nodes", nargs="+", required=True,
                        help="Node path(s)")
    gwatch.add_argument("--props", nargs="+", required=True,
                        help="Prop(s) per node, parallel to nodes "
                             "(JSON list, e.g. '[\"x\",\"y\"]')")
    gwatch.add_argument("--hz", type=float, default=30.0,
                        help="Target sample rate in Hz (fps-adaptive, default 30)")
    gsample = g_sub.add_parser("sample", help="Read the telemetry ring buffer")
    gsample.add_argument("--limit", type=int, default=0,
                         help="Return only the last N samples (0 = all)")
    g_sub.add_parser("telemetry-stop",
                     help="Stop telemetry sampling and discard the buffer")
    gmouse = g_sub.add_parser("mouse")
    gmouse.add_argument("action", choices=["click", "move"])
    gmouse.add_argument("x", type=int)
    gmouse.add_argument("y", type=int)
    gmouse.add_argument("--button", type=int, default=1)
    gmouse.add_argument("--unhandled", action="store_true")
    gclick = g_sub.add_parser("click-node")
    gclick.add_argument("path")
    gclick.add_argument("--button", type=int, default=1)
    gts = g_sub.add_parser("time-scale")
    gts.add_argument("scale", type=float)
    gcs = g_sub.add_parser("change-scene", help="Change scene on the MAIN thread (runs combat._start_from_config)")
    gcs.add_argument("path")
    grpc = g_sub.add_parser("rpc", help="Forward an arbitrary registered bridge method (core or game-registered)")
    grpc.add_argument("method", help="Registered method name, e.g. combat_start_match, combat_snapshot, start_scene")
    grpc.add_argument("--json-params", dest="json_params", default="",
                      help="JSON object of named params, e.g. '{\"x\": 3}'")
    g_sub.add_parser("quit")
    glua_act = g_sub.add_parser("lua-eval-act")
    glua_act.add_argument("code")
    g_sub.add_parser("clear-logs")
    gcr = g_sub.add_parser("crashes", help="Read recent crash/error entries + crash flag")
    gcr.add_argument("--max-lines", dest="max_lines", type=int, default=50)
    g_sub.add_parser("clear-crashes", help="Reset the crash-detected flag")

    d = subparsers.add_parser(
        "debugger",
        help="DAP debugger (4.8+): breakpoints, stepping, stack, variables, evaluate")
    d_sub = d.add_subparsers(dest="debugger_command", required=True)
    d_sub.add_parser("state", help="DAP session state (connected/attached/breaked)")
    d_sub.add_parser("attach", help="Attach to the game currently running in the editor")
    d_sub.add_parser("detach", help="Detach (game keeps running)")
    dlaunch = d_sub.add_parser("launch", help="Start the game through DAP")
    dlaunch.add_argument("--scene", default="", help="res:// path (default: main scene)")
    dlaunch.add_argument("--args", default="", help="Comma-separated play arguments")
    dlaunch.add_argument("--no-debug", action="store_true", help="Skip breakpoints")
    dbp = d_sub.add_parser("break", help="Set a breakpoint (auto-attaches)")
    dbp.add_argument("file", help="res:// path of the script")
    dbp.add_argument("line", type=int)
    dubp = d_sub.add_parser("unbreak", help="Remove a breakpoint (auto-attaches)")
    dubp.add_argument("file")
    dubp.add_argument("line", type=int)
    d_sub.add_parser("breaks", help="List known breakpoints")
    d_sub.add_parser("continue", help="Resume execution")
    d_sub.add_parser("pause", help="Pause the running game")
    d_sub.add_parser("step-over", help="Step over (requires paused)")
    d_sub.add_parser("step-into", help="Step into (requires paused)")
    d_sub.add_parser("step-out", help="Step out (requires paused)")
    d_sub.add_parser("stack", help="Call stack (requires paused)")
    dvars = d_sub.add_parser("vars", help="Scopes or variable children (requires paused)")
    dvars.add_argument("--frame", type=int, default=0, help="Stack frame (0 = innermost)")
    dvars.add_argument("--ref", type=int, default=0,
                       help="variablesReference to expand (scope or object)")
    deval = d_sub.add_parser("eval", help="Evaluate an expression in the paused frame")
    deval.add_argument("expression")
    deval.add_argument("--frame", type=int, default=0)
    dout = d_sub.add_parser("output", help="Game output captured via DAP events")
    dout.add_argument("--from", dest="from_line", type=int, default=0)
    dout.add_argument("--max-lines", type=int, default=200)

    s = subparsers.add_parser("subscribe")
    s_sub = s.add_subparsers(dest="sub_type", required=True)
    s_sub.add_parser("listen", help="Stream all events to stdout")
    se = s_sub.add_parser("events", help="Stream specific events")
    se.add_argument("events", nargs="+")
    s_sub.add_parser("state", help="Stream full-state snapshots on change")
    s_sub.add_parser("console", help="Stream Output panel lines (editor + game)")
    s_sub.add_parser("debugger",
                     help="Stream DAP debugger events (stopped/output/terminated/...)")

    l = subparsers.add_parser(
        "logs",
        help="Fetch or clear bridge logs (default: get — fetch the last N lines)")
    # The `get` flags live on the parent parser so they also work when no
    # subcommand word is typed (e.g. `logs --max-lines 30` or a bare `logs`):
    # with a required subparser the first non-option token was swallowed as a
    # (invalid) `log_type` choice, producing the cryptic
    # "argument log_type: invalid choice: '30'" error (dogfood BD-014).
    l.add_argument("--from", dest="from_line", type=int, default=0)
    l.add_argument("--max-lines", dest="max_lines", type=int, default=500)
    l.add_argument("--source", default="auto",
                   choices=["auto", "panel", "collector", "process"])
    # Optional: when omitted, default to "get" (fetch) at parse time.
    l_sub = l.add_subparsers(dest="log_type")
    lg = l_sub.add_parser("get")
    lg.add_argument("--from", dest="from_line", type=int, default=0)
    lg.add_argument("--max-lines", dest="max_lines", type=int, default=500)
    lg.add_argument("--source", default="auto",
                    choices=["auto", "panel", "collector", "process"])
    l_sub.add_parser("clear")

    return parser


def main() -> None:
    args = build_parser().parse_args()
    # `logs` with no subcommand word defaults to "get" (fetch). An optional
    # subparser yields None when omitted; defaulting at parse time keeps the
    # dispatch block below simple (dogfood BD-014).
    if args.command == "logs" and args.log_type is None:
        args.log_type = "get"
    client = EditorBridgeClient()
    _GLOBAL_CLIENT = client

    try:
        if args.command == "launch":
            state = client.launch()
            print(json.dumps(state, indent=2))
        elif args.command == "restart":
            state = client.restart()
            print(json.dumps(state, indent=2))
        elif args.command in ("ping", "connect"):
            state = client.ping()
            print(json.dumps(state, indent=2))

        elif args.command == "query":
            state = client.ping()  # fail fast if the editor is dead
            if args.query_type == "state":
                result = client.rpc("query.state")
            elif args.query_type == "editor":
                result = client.rpc("query.editor")
            elif args.query_type == "fs-scenes":
                result = client.rpc("query.fs.scenes")
            elif args.query_type == "autoloads":
                result = client.rpc("query.autoloads")
            elif args.query_type == "scene":
                result = client.rpc("query.scene", {"path": args.path})
            elif args.query_type == "scene-tree":
                result = client.rpc("query.scene.tree",
                                    {"path": args.path, "depth": args.depth})
            elif args.query_type == "fs":
                result = client.rpc("query.fs", {"path": args.path})
            elif args.query_type == "fs-scripts":
                result = client.rpc("query.fs.scripts", {"path": args.path})
            elif args.query_type == "dialogs":
                result = client.rpc("query.editor.dialogs")
            elif args.query_type == "godot-status":
                g = state.get("game", {}) or {}
                dbg = state.get("debugger", {}) or {}
                sc = state.get("scenes", {}) or {}
                editor = state.get("editor", {}) or {}
                # A paused game (inherited editor breakpoint on boot, a manual
                # `debugger pause`, or a stop on a breakpoint) is a STATE, not an
                # error. Surface `breaked` + `breakpoint_count` in the turn-start
                # call so the LLM sees the paused state up front instead of
                # discovering it by a later `game ping` -> state.breaked.
                breaked = bool(dbg.get("breaked", False))
                bp_count = int(dbg.get("breakpoint_count") or 0)
                result = {
                    "editor": {"pid": editor.get("pid"), "godot_version": editor.get("godot_version")},
                    "game": {
                        "running": g.get("running"),
                        "playing_scene": g.get("playing_scene"),
                        "bridge_connected": g.get("bridge_connected"),
                        "bridge_port": g.get("bridge_port"),
                    },
                    "scenes": {
                        "current": sc.get("current"),
                        "unsaved": sc.get("unsaved"),
                    },
                    "debugger": {
                        "connected": dbg.get("connected"),
                        "attached": dbg.get("attached"),
                        "breaked": breaked,
                        "breakpoint_count": bp_count,
                    },
                }
                # Legible hint: a running game that is paused with breakpoints set.
                # `breaked: true` is a state, not a timeout — tell the LLM the
                # actionable next step before it tries to drive a frozen game.
                if breaked and bp_count > 0 and g.get("running"):
                    result["note"] = ("game is paused (`breaked: true`) with %d "
                                      "breakpoint(s); `debugger continue` to resume, "
                                      "`debugger unbreak <file> <line>` to clear a "
                                      "breakpoint, or `scene-stop` before driving") % bp_count
                print(json.dumps(_contract_ok(result, _current_state(state)), indent=2))
                return
            elif args.query_type == "human-deltas":
                result = client.rpc("query.human.deltas", {"since": args.since}, timeout=10)
                print(json.dumps(_contract_ok(result, _current_state(state)), indent=2))
                return
            print(json.dumps(_contract_ok(result, _current_state(state)), indent=2))

        elif args.command == "action":
            state = client.ping()
            if args.action_type == "scene-open":
                path = _resolved_path(args)
                if path in state.get("scenes", {}).get("open", []):
                    print("Scene already open: %s" % path, file=sys.stderr)
                    sys.exit(1)
                result = client.rpc("action.scene.open", {"path": path})
            elif args.action_type == "scene-close":
                result = client.rpc("action.scene.close", {"path": args.path})
            elif args.action_type == "scene-save":
                result = client.rpc("action.scene.save", {"path": args.path or ""})
            elif args.action_type == "scene-save-all":
                result = client.rpc("action.scene.save_all", {})
            elif args.action_type == "scene-play":
                if state.get("game", {}).get("running"):
                    print("Error: game already playing %s"
                          % state["game"].get("playing_scene"), file=sys.stderr)
                    print("Run: editor_bridge_cli.py action scene-stop", file=sys.stderr)
                    sys.exit(1)
                result = client.rpc("action.scene.play", {"path": args.path or ""})
            elif args.action_type == "scene-stop":
                result = client.rpc("action.scene.stop", {})
            elif args.action_type == "scene-reload":
                result = client.rpc("action.scene.reload",
                                    {"path": _resolved_path(args)})
            elif args.action_type == "editor-restart":
                result = client.rpc("action.editor.restart", {}, timeout=10)
            elif args.action_type == "editor-close":
                result = client.rpc("action.editor.close", {}, timeout=10)
            elif args.action_type == "scripts-reload":
                result = client.rpc("action.scripts.reload", {}, timeout=SLOW_GAME_OP_TIMEOUT)
            elif args.action_type == "scripts-reload-one":
                result = client.rpc("action.scripts.reload_one", {"path": args.path})
            elif args.action_type == "eval":
                result = client.rpc("action.eval", {"expression": args.expression})
            elif args.action_type == "run-script":
                result = client.rpc("action.script.run",
                                    {"path": args.path, "method": args.method,
                                     "args": args.args})
            elif args.action_type == "scripts-check":
                result = client.rpc("action.scripts.check", {"paths": args.paths})
            elif args.action_type == "fs-scan":
                result = client.rpc("action.fs.scan", {}, timeout=30)
                if args.wait and result.get("ok", True):
                    deadline = time.time() + 120.0
                    while True:
                        time.sleep(0.3)
                        try:
                            st = client.rpc("query.state", timeout=10)
                        except (EditorBridgeError, EditorBridgeNotRunning):
                            st = None  # editor mid-scan and slow to answer; retry
                        if st is not None and not st.get("fs_scanning"):
                            break
                        if time.time() >= deadline:
                            result["scan_timeout"] = True
                            print("Warning: scan still running after 120s",
                                  file=sys.stderr)
                            break
                    result["scan_finished"] = not result.get("scan_timeout")
            elif args.action_type == "dialog-accept":
                result = client.rpc("action.editor.dialog.accept",
                                    {"ok_button": args.ok_button})
            print(json.dumps(_contract_ok(result, _current_state(state)), indent=2))

        elif args.command == "game":
            client.ping()  # fail fast if the editor is dead
            if args.game_command == "ping":
                state = client.read_state() or {}
                out = {
                    "editor": True,
                    "editor_pid": state.get("editor", {}).get("pid"),
                    "game_running": state.get("game", {}).get("running"),
                    "playing_scene": state.get("game", {}).get("playing_scene"),
                }
                try:
                    out.update(client.rpc("game.ping", {}, timeout=5))
                    out["game_bridge"] = True
                except EditorBridgeError as e:
                    out["game_bridge"] = False
                    out["game_bridge_note"] = str(e)
                print(json.dumps(_contract_ok(out, _current_state(state)), indent=2))
                return
            if args.game_command == "rpc":
                method = args.method
                params = _parse_json_params(args.json_params)
                # Combat ops (start_scene with its readiness poll, combat_start_match
                # which loads a scene + waits for live, combat_step which waits for
                # animation) can exceed the 30 s default; give rpc the slow-op budget
                # (same as lua-eval) so a slow-but-valid op isn't killed early.
                rpc_timeout = SLOW_GAME_OP_TIMEOUT
                try:
                    result = client.rpc("game." + method, params, timeout=rpc_timeout)
                except EditorBridgeError as e:
                    _handle_game_error(e)
                print(json.dumps(result, indent=2))
                return
            method, params = GAME_COMMANDS[args.game_command]
            params = params(args)
            timeout = GAME_TIMEOUTS.get(args.game_command, DEFAULT_TIMEOUT)
            # Bounded read-only retry on a transient bridge drop (community v2.3,
            # Phase 3). The game bridge is single-client and a request can be lost
            # (e.g. mid scene-swap, see BD-012). Only idempotent READS are retried —
            # never a mutation (set/call/hold/release/inject_*), which could
            # double-apply. Bounded so it can't hang; --no-retry disables it.
            retries = (0 if getattr(args, "no_retry", False)
                       else (3 if args.game_command in RETRYABLE_GAME_COMMANDS else 0))
            attempt = 0
            while True:
                try:
                    result = client.rpc("game." + method, params, timeout=timeout)
                    break
                except EditorBridgeError as e:
                    if _is_game_transport_failure(e) and attempt < retries:
                        attempt += 1
                        print("  [retry] %s (transport, attempt %d/%d) — %s"
                              % (args.game_command, attempt, retries, e),
                              file=sys.stderr)
                        time.sleep(min(0.5 * attempt, 1.5))
                        continue
                    # Branch on error kind (dogfood BD-006): genuine transport
                    # failures (timeout / disconnect / bridge never reachable) get
                    # the full unreachable-investigation (crash / paused / dropped);
                    # structured errors the editor answered with (policy rejection,
                    # bad node path, method-not-found, compile check) are printed
                    # plainly, since the game was never touched in those cases.
                    _handle_game_error(e)
            if args.game_command in ("screenshot",):
                # Prefer the bridge-reported absolute local_path (the game
                # process resolves user:// via OS.get_user_data_dir() —
                # authoritative). Fall back to the CLI's own computation only
                # for older bridges whose response lacks local_path (dogfood
                # BD-011: the CLI's independent path fell back to the literal
                # "project" name and mismatched the dir the engine writes to).
                if not result.get("local_path"):
                    result["local_path"] = _resolve_user_path(args.path)
            print(json.dumps(result, indent=2))

        elif args.command == "debugger":
            client.ping()
            name_map = {
                "state": "query.debugger.state",
                "attach": "action.debugger.attach",
                "detach": "action.debugger.detach",
                "launch": "action.debugger.launch",
                "break": "action.debugger.break",
                "unbreak": "action.debugger.unbreak",
                "breaks": "query.debugger.breaks",
                "continue": "action.debugger.continue",
                "pause": "action.debugger.pause",
                "step-over": "action.debugger.step_over",
                "step-into": "action.debugger.step_into",
                "step-out": "action.debugger.step_out",
                "stack": "query.debugger.stack",
                "vars": "query.debugger.vars",
                "eval": "query.debugger.eval",
                "output": "query.debugger.output",
            }
            dbg_args = {}
            if args.debugger_command == "launch":
                dbg_args = {
                    "scene": args.scene,
                    "play_args": [a for a in args.args.split(",") if a],
                    "no_debug": args.no_debug,
                }
            if args.debugger_command in ("break", "unbreak"):
                dbg_args = {"file": args.file, "line": args.line}
            if args.debugger_command == "vars":
                dbg_args = ({"ref": args.ref} if args.ref > 0
                            else {"frame": args.frame})
            if args.debugger_command == "eval":
                dbg_args = {"expression": args.expression, "frame": args.frame}
            if args.debugger_command == "output":
                dbg_args = {"from": args.from_line, "max_lines": args.max_lines}
            result = client.rpc(name_map[args.debugger_command], dbg_args)
            print(json.dumps(_contract_ok(result, _current_state()), indent=2))

        elif args.command == "subscribe":
            if args.sub_type == "listen":
                client.listen()
            elif args.sub_type == "events":
                client.listen(events=args.events)
            elif args.sub_type == "state":
                client.listen(state=True)
            elif args.sub_type == "console":
                client.listen(events=["console"])
            elif args.sub_type == "debugger":
                client.listen(events=[
                    "debugger_dap", "debugger_stopped", "debugger_continued",
                    "debugger_output", "debugger_terminated", "debugger_exited",
                    "debugger_breakpoint", "debugger_custom",
                ])

        elif args.command == "logs":
            client.ping()
            if args.log_type == "get":
                result = client.rpc("logs.get", {
                    "from": args.from_line,
                    "max_lines": args.max_lines,
                    "source": args.source,
                })
            else:
                result = client.rpc("logs.clear", {})
            print(json.dumps(result, indent=2))

    except EditorBridgeNotRunning as e:
        print("Error: %s" % e, file=sys.stderr)
        print("Start it with: python3 bridge/cli/editor_bridge_cli.py launch",
              file=sys.stderr)
        sys.exit(2)
    except EditorBridgeError as e:
        print("Error: %s" % e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
