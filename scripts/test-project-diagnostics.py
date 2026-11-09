#!/usr/bin/env python3
"""Light security/contract checks for the app-owned diagnostic MCP tool."""
import importlib.util
import json
import os
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


if __name__ == "__main__":
    unittest.main()
