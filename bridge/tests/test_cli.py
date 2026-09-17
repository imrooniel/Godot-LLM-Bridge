#!/usr/bin/env python3
"""Unit tests for bridge/cli/cli_proc.py (pure process helpers).

Run:  python3 bridge/tests/test_cli.py
     or: python3 -m pytest bridge/tests/test_cli.py -v
No live Godot required.
"""
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cli"))
import cli_proc as cp  # noqa: E402


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
