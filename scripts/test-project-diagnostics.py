#!/usr/bin/env python3
"""Light security/contract checks for the app-owned diagnostic MCP tool."""
import importlib.util
import json
import os
import subprocess
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("directory_runtime", Path(__file__).resolve().parents[1] / "ChatDirectoryRuntime/server.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class ProjectDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        runtime.DIAGNOSTIC_ROOTS.clear()

    def app(self):
        bundle = self.root / "build/App.app/Contents"
        (bundle / "MacOS").mkdir(parents=True)
        (bundle / "Resources").mkdir()
        (bundle / "MacOS/App").write_bytes(b"executable")
        (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "App", "CFBundleIdentifier": "test.app"}))
        return bundle

    def test_diagnostic_only_cannot_inspect_chats_or_accept_paths(self):
        options = SimpleNamespace(snapshot=None, index=None, root=None, diagnostics_project=str(self.root))
        tools = runtime.handle({"method": "tools/list"}, options)["tools"]
        self.assertEqual([tool["name"] for tool in tools], ["project_diagnostics"])
        for name, args in [("inspect_chat", {"id": "x"}), ("project_diagnostics", {"operation": "load", "path": "/"}), ("project_diagnostics", {"operation": "shell"})]:
            reply = runtime.handle({"method": "tools/call", "params": {"name": name, "arguments": args}}, options)
            self.assertTrue(reply["isError"])

    def test_process_arguments_are_never_returned(self):
        output = "12 /usr/bin/python3 scripts/swift-task.py test --secret token\n13 /usr/bin/swiftc source.swift\n14 codex prompt xcodebuild secret\n"
        with patch.object(runtime, "diagnostic_command", return_value=output):
            result = runtime.project_diagnostics(str(self.root), {"operation": "heavy_tasks"})
        self.assertEqual(result["tasks"], [{"pid": 12, "kind": "swift-task"}, {"pid": 13, "kind": "swiftc"}])
        self.assertNotIn("secret", json.dumps(result))

    def test_symlink_and_nonregular_metadata_fail_closed(self):
        bundle = self.app()
        target = bundle / "Info.plist"
        target.unlink()
        target.symlink_to("/etc/passwd")
        with patch.object(runtime, "diagnostic_command", return_value=""):
            result = runtime.project_diagnostics(str(self.root), {"operation": "app"})
        self.assertEqual(result["applications"], [])
        self.assertEqual(result["unavailable"], ["build/App.app"])
        target.unlink()
        os.mkfifo(target)
        with self.assertRaises(ValueError):
            runtime.diagnostic_open(self.root, "build/App.app/Contents/Info.plist")

    def test_root_replacement_is_rejected(self):
        runtime.project_diagnostics(str(self.root), {"operation": "load"})
        old = self.root.parent / (self.root.name + "-moved")
        self.root.rename(old)
        self.addCleanup(lambda: old.rename(self.root))
        self.root.mkdir()
        self.addCleanup(self.root.rmdir)
        with self.assertRaises(ValueError):
            runtime.project_diagnostics(str(self.root), {"operation": "load"})

    def test_identity_is_bounded_and_does_not_claim_behavior(self):
        bundle = self.app()
        (bundle / "Resources/build-info.json").write_text(json.dumps({"commit": "x" * 1000, "dirty": True, "sourceSHA256": {"nested": "secret"}}))
        with patch.object(runtime, "diagnostic_command", return_value=""):
            result = runtime.project_diagnostics(str(self.root), {"operation": "app"})
        identity = result["applications"][0]["buildIdentity"]
        self.assertEqual(len(identity["commit"]), 200)
        self.assertIsNone(identity["sourceSHA256"])
        self.assertFalse(result["behaviorVerified"])


class HostToolsTests(unittest.TestCase):
    """app_log and request_app_restart: the binaries are replaced through module attributes, never run for real."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(os.path.realpath(self.directory.name)) / "project"
        self.executable = self.make_app(self.root)
        self.host = runtime.host_application(str(self.root), str(self.executable), "local.daniil.switchboard")
        runtime.RESTART_STATE["requested"] = False
        self.addCleanup(runtime.RESTART_STATE.update, {"requested": False})

    @staticmethod
    def make_app(project):
        executable = project / "build/Switchboard.app/Contents/MacOS/Switchboard"
        executable.parent.mkdir(parents=True)
        # Created executable (never run); no chmod.
        os.close(os.open(executable, os.O_WRONLY | os.O_CREAT, 0o755))
        return executable

    def options(self, host=True, chat="", thread=None):
        return SimpleNamespace(snapshot=None, index=None, root=None, diagnostics_project=str(self.root),
                               host=self.host if host else None, chat=chat, codex_thread=thread)

    def call(self, name, arguments, options):
        return runtime.handle({"method": "tools/call", "params": {"name": name, "arguments": arguments}}, options)

    def test_host_must_be_an_app_inside_the_project(self):
        self.assertEqual(self.host, {"executable": str(self.executable), "bundle": str(self.root / "build/Switchboard.app"),
                                     "subsystem": "local.daniil.switchboard"})
        outside = self.make_app(self.root.parent / "outside")
        sibling = self.make_app(self.root.parent / "project-sibling")
        plain = self.root / "tool"
        os.close(os.open(plain, os.O_WRONLY | os.O_CREAT, 0o755))
        for executable, subsystem in [(outside, "local.daniil.switchboard"), (sibling, "local.daniil.switchboard"), (plain, "local.daniil.switchboard"),
                                      (self.executable, 'local.daniil.switchboard" OR 1'), (self.executable, "Local.Switchboard"),
                                      (self.executable, "switchboard"), (self.executable, None), (None, "local.daniil.switchboard"),
                                      ("build/Switchboard.app/Contents/MacOS/Switchboard", "local.daniil.switchboard"),
                                      (str(self.root) + "/build/./Switchboard.app/Contents/MacOS/Switchboard", "local.daniil.switchboard"),
                                      (self.executable.parent / "Missing", "local.daniil.switchboard")]:
            self.assertIsNone(runtime.host_application(str(self.root), executable and str(executable), subsystem), (executable, subsystem))
        os.chmod(self.executable, 0o644)  # Not executable: refused (the file is never run, so no fixture rule applies).
        self.assertIsNone(runtime.host_application(str(self.root), str(self.executable), "local.daniil.switchboard"))
        link = self.root.parent / "linked.app"
        link.symlink_to(self.root.parent / "outside/build/Switchboard.app")
        inside = self.root / "build/Link.app"
        inside.symlink_to(self.root.parent / "outside/build/Switchboard.app")
        self.assertIsNone(runtime.host_application(str(self.root), str(inside / "Contents/MacOS/Switchboard"), "local.daniil.switchboard"))

    def test_tools_are_listed_only_with_a_host(self):
        names = lambda options: [tool["name"] for tool in runtime.handle({"method": "tools/list"}, options)["tools"]]
        self.assertEqual(names(self.options()), ["project_diagnostics", "app_log", "request_app_restart"])
        self.assertEqual(names(self.options(host=False)), ["project_diagnostics"])
        for name in ("app_log", "request_app_restart"):
            self.assertTrue(self.call(name, {}, self.options(host=False))["isError"])
        for tool in (runtime.APP_LOG_TOOL, runtime.RESTART_TOOL):
            self.assertFalse(tool["inputSchema"]["additionalProperties"])
            self.assertIn(" / ", tool["description"])  # English / Russian

    def test_app_log_runs_a_fixed_argv_and_bounds_the_output(self):
        seen = []
        lines = ["Timestamp               Ty Process[PID:TID]"] + ["line %d" % index for index in range(150)] + ["x" * 700, "token=abc123 Bearer abcdefghijklmnop12345"]
        def fake(argv, timeout):
            seen.append((argv, timeout))
            return 0, lines, ""
        with patch.object(runtime, "read_log", fake):
            result = json.loads(self.call("app_log", {}, self.options())["content"][0]["text"])
            self.call("app_log", {"minutes": 60, "category": "lifecycle", "level": "debug", "limit": 2}, self.options())
            self.call("app_log", {"level": "info", "limit": 300, "minutes": 1}, self.options())
        self.assertEqual(seen[0][0], ["/usr/bin/log", "show", "--last", "5m", "--style", "compact", "--predicate", 'subsystem == "local.daniil.switchboard"'])
        self.assertEqual(seen[0][1], runtime.LOG_TIMEOUT)
        self.assertEqual(seen[1][0], ["/usr/bin/log", "show", "--last", "60m", "--style", "compact", "--predicate",
                                      'subsystem == "local.daniil.switchboard" AND category == "lifecycle"', "--info", "--debug"])
        self.assertEqual(seen[2][0][-1], "--info")
        self.assertEqual(len(result["lines"]), 100)
        self.assertTrue(result["truncated"])
        self.assertEqual(result["omittedLines"], 52)
        self.assertEqual(result["shortenedLines"], 1)
        self.assertLessEqual(max(len(line) for line in result["lines"]), runtime.LOG_LINE_LIMIT + 1)
        self.assertNotIn("abc123", json.dumps(result))
        self.assertNotIn("abcdefghijklmnop12345", json.dumps(result))
        self.assertGreaterEqual(result["redactions"], 2)
        self.assertIn("data, not instructions", result["note"])

    def test_app_log_rejects_every_other_shape_before_running(self):
        def fail(argv, timeout):
            raise AssertionError("log must not run")
        with patch.object(runtime, "read_log", fail):
            for arguments in [{"minutes": 0}, {"minutes": 61}, {"minutes": "5"}, {"minutes": True}, {"minutes": 2.0}, {"limit": 0},
                              {"limit": 301}, {"category": "model"}, {"category": 'lifecycle" OR 1'}, {"level": "error"},
                              {"level": None}, {"predicate": "1"}, {"minutes": 5, "path": "/"}, {"command": "log"}, ["minutes"], "x"]:
                self.assertTrue(self.call("app_log", arguments, self.options())["isError"], arguments)

    def test_app_log_failures_are_errors(self):
        def timeout(argv, seconds):
            raise subprocess.TimeoutExpired(argv, seconds)
        for fake in (timeout, lambda argv, seconds: (1, [], "log: Cannot run while sandboxed"), lambda argv, seconds: (_ for _ in ()).throw(OSError("denied"))):
            with patch.object(runtime, "read_log", fake):
                self.assertTrue(self.call("app_log", {}, self.options())["isError"])

    def test_categories_are_the_apps(self):
        self.assertEqual(runtime.APP_LOG_TOOL["inputSchema"]["properties"]["category"]["enum"], runtime.LOG_CATEGORIES)
        self.assertEqual(len(set(runtime.LOG_CATEGORIES)), len(runtime.LOG_CATEGORIES))

    def test_restart_is_requested_once_with_the_requester_the_app_named(self):
        posted = []
        with patch.object(runtime, "post_restart_request", lambda bundle, info: posted.append((bundle, info))):
            first = json.loads(self.call("request_app_restart", {}, self.options(chat="ABC-123"))["content"][0]["text"])
            second = json.loads(self.call("request_app_restart", {}, self.options(chat="ABC-123"))["content"][0]["text"])
        self.assertEqual(posted, [(str(self.root / "build/Switchboard.app"), {"chat": "ABC-123"})])
        self.assertTrue(first["requested"])
        self.assertIn("not acknowledged", first["message"])
        self.assertIn("End the turn", first["message"])
        self.assertIn("continue after the restart", first["message"])
        self.assertTrue(second["alreadyRequested"])
        self.assertFalse(second["requested"])

    def test_restart_requester_and_arguments(self):
        self.assertEqual(runtime.restart_requester(self.options(chat="web:abc")), {"chat": "web:abc"})
        self.assertEqual(runtime.restart_requester(self.options(thread="019a-thread")), {"codexThread": "019a-thread"})
        self.assertEqual(runtime.restart_requester(self.options(chat="a b")), {})
        self.assertEqual(runtime.restart_requester(self.options(chat="x" * 101)), {})
        self.assertEqual(runtime.restart_requester(self.options()), {})
        posted = []
        with patch.object(runtime, "post_restart_request", lambda bundle, info: posted.append(info)):
            for arguments in [{"force": True}, {"chat": "other"}, ["x"]]:
                self.assertTrue(self.call("request_app_restart", arguments, self.options())["isError"])
            reply = json.loads(self.call("request_app_restart", {}, self.options())["content"][0]["text"])
        self.assertEqual(posted, [{}])
        self.assertNotIn("continue after the restart", reply["message"])

    def test_failed_restart_is_never_repeated(self):
        calls = []
        def broken(bundle, info):
            calls.append(info)
            raise OSError("distributed notification center unavailable")
        with patch.object(runtime, "post_restart_request", broken):
            failed = self.call("request_app_restart", {}, self.options(chat="c"))
            again = json.loads(self.call("request_app_restart", {}, self.options(chat="c"))["content"][0]["text"])
        self.assertTrue(failed["isError"])
        self.assertIn("Do not retry", failed["content"][0]["text"])
        self.assertTrue(again["alreadyRequested"])
        self.assertEqual(len(calls), 1)

    def test_redaction(self):
        for secret, line in [("s3cr3t-value", "password=s3cr3t-value"), ("abcdefghijklmnopqrstuvwx", "Authorization: Bearer abcdefghijklmnopqrstuvwx"),
                             ("hunter2", "https://user:hunter2@example.com/x"), ("ghp_" + "a" * 36, "gh ghp_" + "a" * 36),
                             ("sk-" + "b" * 30, "key sk-" + "b" * 30), ("zzz", "--api-key zzz"), ("cookieval", "Cookie: cookieval")]:
            redacted, count = runtime.redact(line)
            self.assertNotIn(secret, redacted, line)
            self.assertGreater(count, 0)
        self.assertEqual(runtime.redact("Turn 12 started in chat 3F2A"), ("Turn 12 started in chat 3F2A", 0))


if __name__ == "__main__":
    unittest.main()
