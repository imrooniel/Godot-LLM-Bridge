#!/usr/bin/env python3
"""Unit tests for bridge/cli/cli_proc.py (pure process helpers).

Run:  python3 bridge/tests/test_cli.py
     or: python3 -m pytest bridge/tests/test_cli.py -v
No live Godot required.
"""
import json
import os
import platform
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cli"))
import cli_proc as cp  # noqa: E402
import editor_bridge_cli as ebc  # noqa: E402  (module under test)


def cli_proc_restart_dead(pid: int) -> bool:
    """restart()'s death-wait predicate (C3): the editor is considered
    stopped when its pid is gone — regardless of heartbeat age (a
    modal-blocked editor's heartbeat can go stale while the process lives)."""
    return not cp.pid_alive(pid)


PROJ = "/home/user/MyProject"

# `ps -eo pid=,args=`-style samples (note: pid, space, cmdline).
PS_EDITOR = (
    "101 /opt/godot --editor --path /home/user/MyProject\n"
    "102 /opt/godot --path /home/user/MyProject --editor-pid 101 --remote-debug tcp://127.0.0.1:6007 --scene res://a.tscn\n"
    "103 sleep 100\n"
)
PS_EDITOR_OTHER_PROJ = (
    "201 /opt/godot --editor --path /home/user/Other\n"
)
PS_GAME_ONLY = (
    "301 /opt/godot --path /home/user/MyProject --remote-debug tcp://127.0.0.1:6007 --editor-pid 999\n"
)
PS_TRUNCATED = (
    "401 /opt/godot --editor --path /home/user\n"  # truncated: not this project
)


class TestProcMatching(unittest.TestCase):
    def test_editor_and_game_split(self):
        r = cp.find_godot_procs(PROJ, ps_out=PS_EDITOR)
        self.assertEqual([p for p, _ in r["editors"]], [101])
        self.assertEqual([p for p, _ in r["games"]], [102])

    def test_other_project_ignored(self):
        r = cp.find_godot_procs(PROJ, ps_out=PS_EDITOR_OTHER_PROJ)
        self.assertEqual(r["editors"], [])
        self.assertEqual(r["games"], [])

    def test_game_only_not_editor(self):
        r = cp.find_godot_procs(PROJ, ps_out=PS_GAME_ONLY)
        self.assertEqual(r["editors"], [])
        self.assertEqual([p for p, _ in r["games"]], [301])

    def test_truncated_path_not_matched(self):
        # A2(b): a truncated --path must NOT be treated as this project.
        r = cp.find_godot_procs(PROJ, ps_out=PS_TRUNCATED)
        self.assertEqual(r["editors"], [])

    def test_percent20_normalized(self):
        ps = "101 /opt/godot --editor --path /home/user/My Project\n"
        # (not %20 in this sample; ensure a real %20 also works)
        ps2 = "101 /opt/godot --editor --path /home/user/My%20Project\n"
        self.assertTrue(cp.same_path(cp.proc_path_arg(ps2), "/home/user/My Project"))


class TestPidAlive(unittest.TestCase):
    def test_self_alive(self):
        self.assertTrue(cp.pid_alive(os.getpid()))

    def test_dead_pid(self):
        # Spawn a process that exits immediately, reap it, then probe: its pid
        # is genuinely dead (robust — a fixed large pid like 2**31 is
        # theoretically allocable on 64-bit hosts with a high pid_max).
        child = subprocess.Popen(["true"])
        child.wait()
        self.assertFalse(cp.pid_alive(child.pid))


class TestValidatePath(unittest.TestCase):
    def test_bad_path_empty(self):
        self.assertNotEqual(cp.validate_project_path(""), "")

    def test_bad_path_no_godot(self):
        # A real existing dir with no project.godot exercises the "no project.godot"
        # branch (a non-existent path would hit the "not a directory" branch).
        import tempfile
        d = tempfile.mkdtemp()
        self.assertIn("project.godot", cp.validate_project_path(d))

    def test_good_path(self):
        # The repo root has project.godot.
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        self.assertEqual(cp.validate_project_path(root), "")


class TestLaunchPreflight(unittest.TestCase):
    """The CLI's pre-flight (wired in Task 1) must refuse when an editor is
    already running for THIS project, and must NOT refuse when only a game
    or another project is running (A2)."""

    def _preflight(self, ps_out, project=PROJ):
        # Mirror the exact decision the CLI makes (imported after Task 1 wires
        # it in; until then this asserts against the helper contract).
        r = cp.find_godot_procs(project, ps_out=ps_out)
        return r

    def test_refuse_when_editor_running(self):
        r = self._preflight(PS_EDITOR)
        self.assertTrue(r["editors"], "editor present -> launch must refuse")

    def test_allow_when_only_game_running(self):
        # A2(a): a game process must NOT block a new editor launch.
        r = self._preflight(PS_GAME_ONLY)
        self.assertFalse(r["editors"], "game-only must not block launch")

    def test_allow_when_nothing(self):
        r = self._preflight("501 sleep 1\n")
        self.assertFalse(r["editors"])


class TestRestartWaitDecision(unittest.TestCase):
    """restart()'s death-wait (C3) must treat the editor as DEAD when its pid
    is gone, regardless of heartbeat age, and as ALIVE when the pid is alive
    (even if the heartbeat went stale on a modal)."""

    def test_pid_dead_means_stopped(self):
        self.assertTrue(cli_proc_restart_dead(2147483648), "dead pid -> stopped")

    def test_pid_alive_means_still_running(self):
        self.assertFalse(cli_proc_restart_dead(os.getpid()), "alive pid -> still running")


class TestErrorCarriesClass(unittest.TestCase):
    def test_error_carries_reason_suggested_code(self):
        # code is an int in the real error dict (e.g. -32603); stored as-is.
        e = ebc.EditorBridgeError("boom",
                                 reason="game_paused_or_dropped",
                                 suggested=["debugger state"],
                                 code=-32603)
        self.assertEqual(e.reason, "game_paused_or_dropped")
        self.assertEqual(e.suggested, ["debugger state"])
        self.assertEqual(e.code, -32603)

    def test_error_defaults_empty(self):
        e = ebc.EditorBridgeError("boom")
        self.assertEqual(e.reason, "")
        self.assertEqual(e.suggested, [])
        self.assertEqual(e.code, "")


class TestErrorClassRouting(unittest.TestCase):
    def test_transport_failure_class(self):
        # A timeout/disconnect is a transport failure (drives the DAP
        # investigation), not a structured logic error.
        e = ebc.EditorBridgeError("rpc game.ping: timed out after 5.0s")
        self.assertTrue(ebc._is_game_transport_failure(e))

    def test_structured_error_not_transport(self):
        # A structured logic error (method not found) is NOT a transport
        # failure, even though it is a game-command error.
        e = ebc.EditorBridgeError("rpc game.ping: method not found",
                                 reason="method_not_found")
        self.assertFalse(ebc._is_game_transport_failure(e))

    def test_reason_forces_transport(self):
        # The reason-aware path: a carried transport reason classifies as
        # transport even when the message text has no marker word.
        e = ebc.EditorBridgeError("some neutral message", reason="bridge_dropped")
        self.assertTrue(ebc._is_game_transport_failure(e))

    def test_stale_peer_recovery_is_transport(self):
        # The in-game stale-peer recovery message (game_proxy.gd) must be a
        # transport failure so the retry loop retries it.
        e = ebc.EditorBridgeError(
            "game.query_game_state: previous request lost (stale peer); retry the command")
        self.assertTrue(ebc._is_game_transport_failure(e))


class TestErrorClassNormalization(unittest.TestCase):
    def test_class_from_reason(self):
        self.assertEqual(cp.error_class("game_paused_or_dropped"), "game_paused")
    def test_class_from_code_int(self):
        self.assertEqual(cp.error_class("", -32603), "load_failed")
    def test_class_from_code_stringified(self):
        # e.code may be a stringified int; error_class normalizes it.
        self.assertEqual(cp.error_class("", "-32603"), "load_failed")
    def test_class_default(self):
        self.assertEqual(cp.error_class(""), "unknown")


class TestRecoverDecision(unittest.TestCase):
    def _d(self, editor_alive, game_running, bridge_up, breaked, orphan_pid):
        return cp.recover_plan(
            editor_alive=editor_alive, game_running=game_running,
            bridge_up=bridge_up, breaked=breaked, orphan_pid=orphan_pid)

    def test_editor_dead_relaunch(self):
        p = self._d(False, False, False, False, 0)
        self.assertEqual(p["action"], "relaunch_editor")

    def test_orphan_killed(self):
        p = self._d(True, False, False, False, 4242)
        self.assertEqual(p["action"], "kill_orphan")
        self.assertEqual(p["orphan_pid"], 4242)

    def test_game_running_bridge_down_replay(self):
        p = self._d(True, True, False, False, 0)
        self.assertEqual(p["action"], "replay_scene")

    def test_breaked_continue(self):
        p = self._d(True, True, True, True, 0)
        self.assertEqual(p["action"], "continue_breaked")

    def test_healthy_noop(self):
        p = self._d(True, True, True, False, 0)
        self.assertEqual(p["action"], "ok")


class TestRecoverCommandExists(unittest.TestCase):
    def test_parser_has_recover(self):
        p = ebc.build_parser()
        args = p.parse_args(["recover"])
        self.assertEqual(args.command, "recover")


class TestRestartForce(unittest.TestCase):
    def test_preflight_suppressed_when_force(self):
        # With force=True, a running editor must NOT block (restart already
        # quit it; a lingering pid is force-killed, not a reason to refuse).
        r = cp.find_godot_procs(PROJ, ps_out=PS_EDITOR)
        self.assertTrue(cp.launch_should_refuse(r, force=True) is False)
    def test_preflight_refuses_when_not_force(self):
        r = cp.find_godot_procs(PROJ, ps_out=PS_EDITOR)
        self.assertTrue(cp.launch_should_refuse(r, force=False) is True)


class TestOrphanKill(unittest.TestCase):
    def test_orphan_kill_flag(self):
        r = cp.find_godot_procs(PROJ, ps_out=PS_GAME_ONLY)
        self.assertTrue(cp.should_kill_orphans(r, force=True))
    def test_orphan_not_killed_without_force(self):
        r = cp.find_godot_procs(PROJ, ps_out=PS_GAME_ONLY)
        self.assertFalse(cp.should_kill_orphans(r, force=False))
    def test_no_kill_when_no_games(self):
        # The bool(procs["games"]) half of the `and`: force alone is not enough
        # when there is no orphan game to kill.
        r = cp.find_godot_procs(PROJ, ps_out=PS_EDITOR_OTHER_PROJ)
        self.assertFalse(cp.should_kill_orphans(r, force=True))


class TestSuiteResultMarker(unittest.TestCase):
    # suite_marker checks the parsed on-disk result dict (the file is JSON,
    # not a SUITE_OK= line).
    def test_trustworthy_when_green(self):
        self.assertEqual(cp.suite_marker({"ok": True, "fail": 0}), "TRUSTWORTHY")
    def test_incomplete_when_not_green(self):
        self.assertEqual(cp.suite_marker({"ok": True, "fail": 3}), "INCOMPLETE")
    def test_incomplete_when_ok_false(self):
        self.assertEqual(cp.suite_marker({"ok": False, "fail": 0}), "INCOMPLETE")
    def test_incomplete_when_missing(self):
        self.assertEqual(cp.suite_marker(None), "INCOMPLETE")


# --- generalized `suite-result --path` (S8 generalization) ------------------
# All new test method names contain lowercase "suite" so that the case-
# sensitive `-k suite` filter selects the whole surface regardless of class.

def _fake_home(home: str):
    """os.path.expanduser replacement: maps a leading "~" to a fake home so
    resolution tests never touch the real ~/.local."""
    def expanduser(path):
        return home + path[1:] if path.startswith("~") else path
    return expanduser


def _app_userdata_base(home: str) -> str:
    """Mirror of _project_user_dir()'s base computation (same platform
    branch), anchored at the fake home instead of the real one."""
    rel = ("~/.local/share/godot/app_userdata" if platform.system() != "Windows"
           else "~/AppData/Roaming/godot/app_userdata")
    return home + rel[1:]


class TestSuiteMarkerContract(unittest.TestCase):
    # Pins the marker contract `suite-result` relies on. The green / red /
    # ok-False cases live in TestSuiteResultMarker above; these cover the
    # missing-key shapes ("fail"/"total" absent) named in the brief.
    def test_suite_marker_fail_key_absent_is_incomplete(self):
        # A dict without "fail" (e.g. only "total") proves the run never
        # reached the summary write — never trustworthy.
        self.assertEqual(cp.suite_marker({"ok": True, "total": 5}), "INCOMPLETE")

    def test_suite_marker_empty_dict_is_incomplete(self):
        self.assertEqual(cp.suite_marker({}), "INCOMPLETE")


class TestSuiteUserPathResolution(unittest.TestCase):
    # _resolve_user_path semantics are KEPT (brief): user:// maps onto the
    # project's app_userdata dir; everything else passes through. The
    # project-name read (PROJECT_ROOT) and the home base (expanduser) are
    # injected — the real ~/.local is never touched.
    def _resolved(self, proj_name, path, home="/home/fakehome"):
        import shutil
        import tempfile
        root = tempfile.mkdtemp()
        try:
            with open(os.path.join(root, "project.godot"), "w") as f:
                f.write('config_version=5\nconfig/name="%s"\n' % proj_name)
            with mock.patch.object(ebc, "PROJECT_ROOT", root), \
                 mock.patch("os.path.expanduser", side_effect=_fake_home(home)):
                return ebc._resolve_user_path(path)
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_suite_user_scheme_maps_onto_app_userdata(self):
        got = self._resolved("FakeProj", "user://x.json")
        expected = os.path.join(_app_userdata_base("/home/fakehome"),
                                "FakeProj", "x.json")
        self.assertEqual(got, expected)

    def test_suite_absolute_path_passes_through(self):
        self.assertEqual(self._resolved("FakeProj", "/tmp/suite.json"),
                         "/tmp/suite.json")

    def test_suite_relative_path_passes_through(self):
        # The resolver itself is scheme-only; project-relative anchoring on
        # PROJECT_ROOT happens in suite_result() (TestSuiteResultPath below).
        self.assertEqual(self._resolved("FakeProj", "out/suite.json"),
                         "out/suite.json")


class TestSuiteResultPath(unittest.TestCase):
    """`suite-result --path PATH` replaces the MW-ism `--which main|reset`:
    accepts user://, res://(-adjacent project-relative), or absolute paths;
    success envelope is {ok, state, result, marker}; an absent file yields the
    contract error reason="suite_result_missing" — never a bare traceback."""

    def setUp(self):
        # Real client: __init__ only (re)creates the gitignored .tmp/bridge
        # mailbox dirs and age-bounded-purges them — safe by construction.
        self.client = ebc.EditorBridgeClient()
        self._dirs = []

    def tearDown(self):
        import shutil
        while self._dirs:
            shutil.rmtree(self._dirs.pop(), ignore_errors=True)

    def _tmpdir(self):
        import tempfile
        d = tempfile.mkdtemp()
        self._dirs.append(d)
        return d

    def _write(self, directory, name, text):
        path = os.path.join(directory, name)
        with open(path, "w") as f:
            f.write(text)
        return path

    def _parse(self, argv):
        # argparse writes usage/errors to stderr; keep the test output clean.
        import contextlib
        import io
        with contextlib.redirect_stderr(io.StringIO()):
            return ebc.build_parser().parse_args(argv)

    # -- parser surface ------------------------------------------------------
    def test_suite_result_parser_accepts_path(self):
        args = self._parse(["suite-result", "--path", "user://suite_result_main.json"])
        self.assertEqual(args.command, "suite-result")
        self.assertEqual(args.path, "user://suite_result_main.json")

    def test_suite_result_parser_requires_path(self):
        with self.assertRaises(SystemExit):
            self._parse(["suite-result"])

    def test_suite_result_parser_rejects_which(self):
        # The MW-ism is gone: --which must no longer parse.
        with self.assertRaises(SystemExit):
            self._parse(["suite-result", "--which", "main"])

    # -- success envelope ----------------------------------------------------
    def test_suite_result_green_envelope_shape(self):
        path = self._write(self._tmpdir(), "suite.json",
                           json.dumps({"ok": True, "fail": 0, "total": 12}))
        res = self.client.suite_result(path)
        self.assertEqual(set(res.keys()), {"ok", "state", "result", "marker"})
        self.assertTrue(res["ok"])
        self.assertEqual(res["marker"], "TRUSTWORTHY")
        self.assertEqual(res["result"]["total"], 12)

    def test_suite_result_red_run_envelope_ok_marker_incomplete(self):
        # File present but the suite red: the READ succeeded (ok True);
        # consumers gate on marker, which is INCOMPLETE (unchanged suite_marker).
        path = self._write(self._tmpdir(), "suite.json",
                           json.dumps({"ok": True, "fail": 2, "total": 5}))
        res = self.client.suite_result(path)
        self.assertTrue(res["ok"])
        self.assertEqual(res["marker"], "INCOMPLETE")

    # -- error envelopes (no bare tracebacks) --------------------------------
    def test_suite_result_missing_file_contract_error(self):
        missing = os.path.join(self._tmpdir(), "absent.json")
        res = self.client.suite_result(missing)
        self.assertFalse(res["ok"])
        self.assertIn("state", res)
        err = res["error"]
        self.assertEqual(err["reason"], "suite_result_missing")
        for key in ("code", "message", "reason", "suggested"):
            self.assertIn(key, err)
        self.assertTrue(err["suggested"], "missing-file error must carry next steps")
        self.assertIn(missing, err["message"], "message names the resolved path")

    def test_suite_result_malformed_json_contract_error(self):
        # A corrupt/partial result file must surface as a contract envelope,
        # never a json.JSONDecodeError traceback.
        path = self._write(self._tmpdir(), "suite.json", "{not json")
        res = self.client.suite_result(path)
        self.assertFalse(res["ok"])
        self.assertEqual(res["error"]["reason"], "suite_result_unreadable")
        self.assertIn(path, res["error"]["message"])
        self.assertIn("not valid JSON", res["error"]["message"])

    def test_suite_result_directory_reports_missing_not_bad_json(self):
        # A directory (e.g. `--path .` -> project root) is missing-for-our-
        # purposes: reason stays suite_result_missing and the message must NOT
        # claim a JSON parse error (the failure is IsADirectoryError).
        d = self._tmpdir()
        res = self.client.suite_result(d)
        self.assertFalse(res["ok"])
        self.assertEqual(res["error"]["reason"], "suite_result_missing")
        self.assertIn(d, res["error"]["message"])
        self.assertIn("not a regular file", res["error"]["message"])
        self.assertNotIn("JSON", res["error"]["message"])

    def test_suite_result_os_error_on_read_reports_accurately(self):
        # A real file that fails to OPEN (permissions here) must report the OS
        # failure, never "is not valid JSON". Skipped where permissions are
        # not enforced (root) or the platform is unreliable (non-POSIX).
        import errno
        path = self._write(self._tmpdir(), "suite.json",
                           json.dumps({"ok": True, "fail": 0}))
        if os.name != "posix":
            self.skipTest("chmod-based permission denial is POSIX-only")
        os.chmod(path, 0o000)
        try:
            try:  # probe: root (or a lax fs) can still open 0o000 files
                open(path).close()
                self.skipTest("permissions not enforced for this user (root?)")
            except OSError as probe:
                self.assertEqual(probe.errno, errno.EACCES)
            res = self.client.suite_result(path)
        finally:
            os.chmod(path, 0o600)  # keep tearDown's rmtree/collect happy
        self.assertFalse(res["ok"])
        self.assertEqual(res["error"]["reason"], "suite_result_unreadable")
        self.assertIn("could not be read", res["error"]["message"])
        self.assertNotIn("JSON", res["error"]["message"])

    # -- path forms ----------------------------------------------------------
    def test_suite_result_relative_and_res_scheme_anchor_project_root(self):
        import shutil
        import tempfile
        root = tempfile.mkdtemp()
        self._dirs.append(root)
        os.makedirs(os.path.join(root, "out"))
        self._write(os.path.join(root, "out"), "suite.json",
                    json.dumps({"ok": True, "fail": 0}))
        with mock.patch.object(ebc, "PROJECT_ROOT", root):
            rel = self.client.suite_result(os.path.join("out", "suite.json"))
            res_scheme = self.client.suite_result("res://out/suite.json")
        self.assertTrue(rel["ok"], "project-relative path must resolve")
        self.assertTrue(res_scheme["ok"], "res://-adjacent form must resolve")

    def test_suite_result_user_scheme_reads_mapped_app_userdata(self):
        import shutil
        import tempfile
        root = tempfile.mkdtemp()   # fake project root (project-name read)
        home = tempfile.mkdtemp()   # fake home — real ~/.local never touched
        self._dirs.extend([root, home])
        self._write(root, "project.godot", 'config_version=5\nconfig/name="FakeProj"\n')
        appdata = os.path.join(_app_userdata_base(home), "FakeProj")
        os.makedirs(appdata)
        self._write(appdata, "suite.json",
                    json.dumps({"ok": True, "fail": 0, "total": 7}))
        with mock.patch.object(ebc, "PROJECT_ROOT", root), \
             mock.patch("os.path.expanduser", side_effect=_fake_home(home)):
            res = self.client.suite_result("user://suite.json")
        self.assertTrue(res["ok"])
        self.assertEqual(res["result"]["total"], 7)
        self.assertEqual(res["marker"], "TRUSTWORTHY")


class TestDapAutoAttach(unittest.TestCase):
    def test_state_changing_commands(self):
        self.assertTrue(cp.dap_needs_attach("continue"))
        self.assertTrue(cp.dap_needs_attach("stack"))
        self.assertFalse(cp.dap_needs_attach("state"))
        self.assertFalse(cp.dap_needs_attach("break"))


class TestDapTimeoutMessage(unittest.TestCase):
    def test_editor_alive_dap_hung(self):
        self.assertEqual(cp.dap_timeout_message(editor_alive=True),
                         "DAP request hung (game paused/busy) — try `debugger continue`; editor is alive")
    def test_editor_dead(self):
        self.assertEqual(cp.dap_timeout_message(editor_alive=False),
                         "editor dead — run `restart`")


class TestRpcParamsAlias(unittest.TestCase):
    def test_params_alias_accepted(self):
        p = ebc.build_parser()
        args = p.parse_args(["game", "rpc", "query_game_state", "--params", '{"x": 3}'])
        self.assertEqual(args.json_params, '{"x": 3}')
    def test_json_params_still_works(self):
        p = ebc.build_parser()
        args = p.parse_args(["game", "rpc", "query_game_state", "--json-params", '{"x": 3}'])
        self.assertEqual(args.json_params, '{"x": 3}')


if __name__ == "__main__":
    unittest.main(verbosity=2)
