#!/usr/bin/env python3
"""Check release metadata without compiling, signing, or registering an app."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


BUILD_SCRIPT = Path(__file__).with_name("build-app.sh")


class BuildAppMetadataTests(unittest.TestCase):
    def run_build(self, values):
        temporary = tempfile.TemporaryDirectory(prefix="lulu-build-metadata-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "scripts").mkdir()
        (root / "bin").mkdir()
        (root / "stubs").mkdir()
        shutil.copyfile(BUILD_SCRIPT, root / "scripts/build-app.sh")
        (root / "bin/InfraTerminal").write_text("fixture executable\n")
        (root / "scripts/make-icon.sh").write_text('touch "$2"\n')
        for filename in ["check-licenses.py", "check-no-keychain.py"]:
            (root / "scripts" / filename).write_text("# Metadata fixture: dependency checks run in the real release build.\n")
        swift = root / "stubs/swift"
        swift.write_text('#!/bin/sh\ncase "$*" in *--show-bin-path*) printf "%s\\n" "$PWD/bin";; *) touch "$PWD/swift-called";; esac\n')
        swift.chmod(0o755)
        codesign = root / "stubs/codesign"
        codesign.write_text("#!/bin/sh\nexit 0\n")
        codesign.chmod(0o755)
        environment = dict(os.environ)
        environment.pop("APP_VERSION", None)
        environment.pop("APP_BUILD_NUMBER", None)
        environment.update(values)
        environment["PATH"] = str(root / "stubs") + os.pathsep + environment["PATH"]
        result = subprocess.run(["bash", "scripts/build-app.sh"], cwd=root,
                                env=environment, text=True, capture_output=True)
        return root, result

    def test_defaults_and_explicit_release_match_plist(self):
        for values, version, build in [({}, "0.1.0", "1"),
                                        ({"APP_VERSION": "2.3.4", "APP_BUILD_NUMBER": "42"}, "2.3.4", "42")]:
            with self.subTest(values=values):
                root, result = self.run_build(values)
                self.assertEqual(result.returncode, 0, result.stderr)
                with (root / "dist/Infra Terminal.app/Contents/Info.plist").open("rb") as handle:
                    info = plistlib.load(handle)
                self.assertEqual(info["CFBundleShortVersionString"], version)
                self.assertEqual(info["CFBundleVersion"], build)

    def test_invalid_metadata_stops_before_build_or_output(self):
        invalid = [{"APP_VERSION": value} for value in ["", "v0.1.0", "1.0", "1.2.3</string>", "1.2.3\n"]]
        invalid += [{"APP_BUILD_NUMBER": value} for value in ["", "0", "01", "-1", "1.0", "abc"]]
        for values in invalid:
            with self.subTest(values=values):
                root, result = self.run_build(values)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / "swift-called").exists())
                self.assertFalse((root / "dist").exists())


if __name__ == "__main__":
    unittest.main()
