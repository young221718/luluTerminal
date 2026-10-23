#!/usr/bin/env python3
"""Verify a stable askpass identity across build roots without reading Keychain."""
from pathlib import Path
import argparse
import hashlib
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, help="Also verify the helper signature survived app packaging")
args = parser.parse_args()

def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)

with tempfile.TemporaryDirectory(prefix="lulu-askpass-test-") as folder:
    temp = Path(folder)
    copy = temp / "other-build-root"
    for name in ["InfraCore", "InfraSSHAskpass"]:
        shutil.copytree(root / "Sources" / name, copy / "Sources" / name)
    (copy / "scripts").mkdir()
    shutil.copy2(root / "scripts/build-askpass-helper.sh", copy / "scripts/build-askpass-helper.sh")
    # A UI-only change must not become part of the helper's code identity.
    (copy / "Sources/InfraTerminalUI").mkdir()
    (copy / "Sources/InfraTerminalUI/Unrelated.swift").write_text("let title = \"Changed UI\"\n")
    first = temp / "first/luluTerminalKeychain"
    second = temp / "second/luluTerminalKeychain"
    for source, output in [(root, first), (copy, second)]:
        output.parent.mkdir()
        run("bash", str(source / "scripts/build-askpass-helper.sh"), str(output))
        run("codesign", "--verify", "--strict", str(output))
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    assert sha(first) == sha(second), "Identical helper sources must retain the same identity across build roots"
    identity = run("codesign", "-d", "-v", "-r-", str(first)).stderr
    assert "Identifier=dev.chanyoung.infra-terminal.keychain" in identity
    if args.app:
        run("codesign", "--verify", "--deep", "--strict", str(args.app))
        packaged = args.app / "Contents/Helpers/luluTerminalKeychain"
        assert sha(packaged) == sha(first), "App packaging must preserve the helper's exact signature and bytes"
        print("Packaged app preserves the standalone helper identity and passes strict nested signature verification.")
    linked = run("otool", "-L", str(first)).stdout
    assert "SwiftUI" not in linked and "AppKit" not in linked and "Ghostty" not in linked
    for args in [[], ["--ssh-askpass", "Verification code: "], ["--ssh-askpass", "fixture@fixture.invalid's password: "]]:
        result = subprocess.run([str(first), *args], capture_output=True, env={**os.environ, "SSH_ASKPASS_REQUIRE": "force"})
        assert result.returncode != 0 and not result.stdout, "Invalid helper invocations must produce no password"
    print("Askpass identity stable across two build roots; signed CLI rejects invalid calls without Keychain access.")
