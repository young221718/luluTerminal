#!/usr/bin/env python3
"""Check audited license inputs and, optionally, their packaged app copies."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def check(app=None):
    root = Path(__file__).resolve().parent.parent
    directory = root / "docs/licenses"
    manifest = json.loads((directory / "manifest.json").read_text())
    pins = {pin["identity"]: pin["state"]["revision"]
            for pin in json.loads((root / "Package.resolved").read_text())["pins"]}
    expected = {"libghostty-spm": manifest["libghostty_spm_revision"],
                "displaylink": manifest["displaylink_revision"]}
    if pins != expected:
        raise ValueError("Package.resolved changed; review dependency licenses and manifest.json")
    notices = manifest["notices"]
    names = [notice["file"] for notice in notices]
    if not names or len(names) != len(set(names)) or set(names) != {p.name for p in directory.glob("*.txt")}:
        raise ValueError("License manifest and notice file inventory differ")
    combined = (root / "docs/THIRD_PARTY.md").read_text()
    for notice in sorted(notices, key=lambda value: value["file"]):
        name = notice["file"]
        if Path(name).name != name or not name.endswith(".txt") or not notice["source"].startswith("https://"):
            raise ValueError(f"Invalid license manifest entry: {name}")
        content = (directory / name).read_bytes()
        if not content or hashlib.sha256(content).hexdigest() != notice["sha256"]:
            raise ValueError(f"License text changed or empty: {name}; review original source")
        combined += f"\n\n===== {name} =====\n\n" + content.decode("utf-8")
    checkout = root / ".build/checkouts/libghostty-spm"
    if checkout.exists():
        revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
        if revision != expected["libghostty-spm"]:
            raise ValueError("libghostty-spm checkout differs from audited revision")
        if (checkout / "Ghostty.ref").read_text().strip() != manifest["ghostty_revision"]:
            raise ValueError("Ghostty source revision changed; repeat license audit")
        if manifest["binary_checksum"] not in (checkout / "Package.swift").read_text():
            raise ValueError("Ghostty binary checksum changed; repeat license audit")
        for filename, source in [("libghostty-spm.txt", checkout / "LICENSE"),
                                 ("bash-preexec.txt", checkout / "Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/bash/LICENSE-bash-preexec.md")]:
            if (directory / filename).read_bytes() != source.read_bytes():
                raise ValueError(f"Audited original differs from checkout: {filename}")
    displaylink = root / ".build/checkouts/DisplayLink/LICENSE"
    if displaylink.exists() and (directory / "DisplayLink.txt").read_bytes() != displaylink.read_bytes():
        raise ValueError("DisplayLink original differs from audited license")
    if app:
        resources = Path(app) / "Contents/Resources"
        bundled = resources / "Licenses"
        for name in names:
            if (bundled / name).read_bytes() != (directory / name).read_bytes():
                raise ValueError(f"Packaged license differs: {name}")
        if (bundled / "THIRD_PARTY.md").read_bytes() != (root / "docs/THIRD_PARTY.md").read_bytes():
            raise ValueError("Packaged license index differs")
        if (bundled / "THIRD_PARTY_NOTICES.txt").read_text() != combined:
            raise ValueError("Packaged combined notices incomplete or stale")
        integrations = list(resources.glob("*.bundle/Ghostty/shell-integration"))
        expected_shell = {"bash/LICENSE-bash-preexec.md", "bash/bash-preexec.sh", "bash/ghostty.bash",
                          "zsh/.zshenv", "zsh/ghostty-integration"}
        if not integrations:
            raise ValueError("Packaged shell integration resources missing")
        for integration in integrations:
            actual_shell = {p.relative_to(integration).as_posix() for p in integration.rglob("*") if p.is_file()}
            if actual_shell != expected_shell:
                raise ValueError("Packaged shell integration differs from audited MIT file set")
            if (integration / "bash/LICENSE-bash-preexec.md").read_bytes() != (directory / "bash-preexec.txt").read_bytes():
                raise ValueError("Packaged bash-preexec resource notice changed")
    print(f"License check passed: {len(notices)} audited notices" + (f"; app {app}" if app else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="also validate the packaged .app")
    args = parser.parse_args()
    try:
        check(args.app)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"License check failed: {error}", file=sys.stderr)
        sys.exit(1)
