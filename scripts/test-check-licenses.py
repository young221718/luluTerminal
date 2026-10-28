#!/usr/bin/env python3
"""Regression checks for audited shell resources in SwiftPM bundle layouts."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("check_licenses", Path(__file__).with_name("check-licenses.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ShellIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lulu-license-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.resources = self.root / "Resources"
        self.notices = self.root / "Licenses"
        self.notices.mkdir()
        (self.notices / "bash-preexec.txt").write_bytes(b"audited notice\n")

    def bundle(self, layout):
        integration = self.resources / layout / "Ghostty/shell-integration"
        for name in ["bash/LICENSE-bash-preexec.md", "bash/bash-preexec.sh", "bash/ghostty.bash",
                     "zsh/.zshenv", "zsh/ghostty-integration"]:
            path = integration / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"audited notice\n" if name.endswith(".md") else b"fixture\n")
        return integration

    def test_flat_bundle(self):
        self.bundle("GhosttyTerminal.bundle")
        checker.check_shell_integrations(self.resources, self.notices)

    def test_macos_bundle(self):
        self.bundle("GhosttyTerminal.bundle/Contents/Resources")
        checker.check_shell_integrations(self.resources, self.notices)

    def test_missing_bundle_rejected(self):
        with self.assertRaisesRegex(ValueError, "resources missing"):
            checker.check_shell_integrations(self.resources, self.notices)

    def test_extra_file_in_either_layout_rejected(self):
        for layout in ["Flat.bundle", "Mac.bundle/Contents/Resources"]:
            with self.subTest(layout=layout):
                integration = self.bundle(layout)
                extra = integration / "unreviewed.sh"
                extra.write_bytes(b"fixture\n")
                with self.assertRaisesRegex(ValueError, "audited MIT file set"):
                    checker.check_shell_integrations(self.resources, self.notices)
                extra.unlink()

    def test_changed_notice_in_either_layout_rejected(self):
        for layout in ["Flat.bundle", "Mac.bundle/Contents/Resources"]:
            with self.subTest(layout=layout):
                integration = self.bundle(layout)
                notice = integration / "bash/LICENSE-bash-preexec.md"
                notice.write_bytes(b"changed\n")
                with self.assertRaisesRegex(ValueError, "resource notice changed"):
                    checker.check_shell_integrations(self.resources, self.notices)
                notice.write_bytes(b"audited notice\n")


if __name__ == "__main__":
    unittest.main()
