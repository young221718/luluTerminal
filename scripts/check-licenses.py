#!/usr/bin/env python3
"""Check audited license inputs and, optionally, their packaged app copies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def check_local_build(checkout, manifest):
    provenance_path = checkout / "BinaryTarget/ghostty-build-provenance.json"
    raw = provenance_path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != manifest["local_provenance_sha256"]:
        raise ValueError("Local Ghostty provenance is not the approved build; review its candidate record")
    provenance = json.loads(raw)
    for key in ["patches", "buildInputs", "engineChanges"]:
        if provenance[key] != manifest["local_build_policy"][key]:
            raise ValueError(f"Local Ghostty provenance inputs changed: {key}")
    if provenance["toolchain"]["zigVersion"] != "0.17.0" or provenance["build"] != manifest["local_build_policy"]["build"]:
        raise ValueError("Local Ghostty build configuration differs from policy")
    if provenance["schemaVersion"] != 1 or provenance["engine"]["revision"] != manifest["ghostty_revision"] or provenance["wrapper"]["revision"] != manifest["libghostty_spm_revision"]:
        raise ValueError("Local Ghostty build inputs differ from the audited revisions")
    if provenance["build"]["platform"] != "macos" or set(provenance["build"]["architectures"]) != {"arm64", "x86_64"}:
        raise ValueError("Local Ghostty build must include both macOS architectures")
    if "-Di18n=false" not in provenance["build"]["flags"]:
        raise ValueError("Local Ghostty build must disable libintl")
    wrapper_files = manifest["local_wrapper_files"]
    expected_sources = {"Package.swift", "Ghostty.ref"} | {p.relative_to(checkout).as_posix() for target in ["GhosttyKit", "GhosttyTerminal"] for p in (checkout / "Sources" / target).rglob("*") if p.is_file()}
    if {entry["path"] for entry in wrapper_files} != expected_sources:
        raise ValueError("Local Ghostty wrapper source inventory differs")
    for record in provenance["patches"] + provenance["buildInputs"] + wrapper_files:
        relative = Path(record["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid local Ghostty input path")
        if hashlib.sha256((checkout / relative).read_bytes()).hexdigest() != record["sha256"]:
            raise ValueError(f"Local Ghostty build input changed: {relative}")
    artifact = checkout / provenance["artifact"]["path"]
    if artifact.resolve() != (checkout / "BinaryTarget/GhosttyKit.xcframework").resolve():
        raise ValueError("Unexpected local Ghostty artifact path")
    records = provenance["artifact"]["files"]
    paths = [record["path"] for record in records]
    if not paths or not any(Path(path).name == "ghostty.h" for path in paths) or len(paths) != len(set(paths)) or set(paths) != {p.relative_to(artifact).as_posix() for p in artifact.rglob("*") if p.is_file()}:
        raise ValueError("Local Ghostty artifact inventory differs")
    for record in records:
        path = artifact / record["path"]
        if not path.resolve().is_relative_to(artifact.resolve()):
            raise ValueError("Invalid local Ghostty artifact entry")
        data = path.read_bytes()
        if len(data) != record["sizeBytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise ValueError(f"Local Ghostty artifact changed: {record['path']}")
    archives = provenance["artifact"]["archives"]
    if len(archives) != 1:
        raise ValueError("Expected one universal macOS Ghostty archive")
    for archive in archives:
        path = artifact / archive["path"]
        if archive["path"] not in paths or {entry["name"] for entry in archive["architectures"]} != {"arm64", "x86_64"}:
            raise ValueError("Local Ghostty archive slice inventory differs")
        actual = set(subprocess.check_output(["lipo", "-archs", str(path)], text=True).split())
        if actual != {"arm64", "x86_64"}:
            raise ValueError("Local Ghostty archive architecture mismatch")
        for architecture in archive["architectures"]:
            with tempfile.TemporaryDirectory(prefix="lulu-ghostty-slice-") as temporary:
                thin = Path(temporary) / "libghostty.a"
                subprocess.run(["lipo", str(path), "-thin", architecture["name"], "-output", str(thin)], check=True)
                data = thin.read_bytes()
                commands = subprocess.check_output(["otool", "-l", str(thin)], text=True)
                minimums = sorted(set(re.findall(r"^\s*minos\s+(\S+)", commands, re.MULTILINE)))
                if not minimums or minimums != architecture["minimumDeploymentTargets"] or any(tuple(map(int, version.split("."))) > (14, 0, 0) for version in minimums):
                    raise ValueError("Local Ghostty archive exceeds macOS 14 deployment target")
            if hashlib.sha256(data).hexdigest() != architecture["sha256"]:
                raise ValueError(f"Local Ghostty slice changed: {architecture['name']}")
        symbols = subprocess.check_output(["nm", "-gU", str(path)], text=True)
        if "libintl_" in symbols:
            raise ValueError("Local Ghostty archive contains libintl definitions")


def check_shell_integrations(resources, directory):
    integrations = list(resources.glob("*.bundle/Ghostty/shell-integration"))
    integrations += list(resources.glob("*.bundle/Contents/Resources/Ghostty/shell-integration"))
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


def check(app=None, copy_to=None):
    root = Path(__file__).resolve().parent.parent
    directory = root / "docs/licenses"
    local = os.environ.get("LULU_GHOSTTY_PACKAGE") or str(root / ".cache/ghostty14/libghostty-spm")
    manifest = json.loads((directory / "manifest-ghostty14.json").read_text())
    pins = {pin["identity"]: pin["state"]["revision"]
            for pin in json.loads((root / "Package.resolved").read_text())["pins"]}
    expected = {"libghostty-spm": manifest["libghostty_spm_revision"],
                "displaylink": manifest["displaylink_revision"]}
    if pins != {"displaylink": expected["displaylink"]}:
        raise ValueError("Package.resolved changed; review dependency licenses and manifest.json")
    notices = manifest["notices"]
    names = [notice["file"] for notice in notices]
    if not names or len(names) != len(set(names)) or set(names) != {p.name for p in directory.glob("*.txt")}:
        raise ValueError("License manifest and notice file inventory differ")
    index = root / "docs/THIRD_PARTY.ghostty14.md"
    combined = index.read_text()
    sources = {}
    for notice in sorted(notices, key=lambda value: value["file"]):
        name = notice["file"]
        if Path(name).name != name or not name.endswith(".txt") or not notice["source"].startswith("https://"):
            raise ValueError(f"Invalid license manifest entry: {name}")
        source = directory / notice.get("source_file", name)
        if not source.resolve().is_relative_to(directory.resolve()):
            raise ValueError(f"Invalid notice source: {name}")
        sources[name] = source
        content = source.read_bytes()
        if not content or hashlib.sha256(content).hexdigest() != notice["sha256"]:
            raise ValueError(f"License text changed or empty: {name}; review original source")
        combined += f"\n\n===== {name} =====\n\n" + content.decode("utf-8")
    checkout = Path(local).resolve()
    if not checkout.is_dir():
        raise ValueError("Local Ghostty package missing")
    if checkout.exists():
        revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
        if revision != expected["libghostty-spm"]:
            raise ValueError("libghostty-spm checkout differs from audited revision")
        if (checkout / "Ghostty.ref").read_text().strip() != manifest["ghostty_revision"]:
            raise ValueError("Ghostty source revision changed; repeat license audit")
        check_local_build(checkout, manifest)
        for filename, source in [("libghostty-spm.txt", checkout / "LICENSE"),
                                 ("bash-preexec.txt", checkout / "Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/bash/LICENSE-bash-preexec.md")]:
            if (directory / filename).read_bytes() != source.read_bytes():
                raise ValueError(f"Audited original differs from checkout: {filename}")
    displaylink = root / ".build/checkouts/DisplayLink/LICENSE"
    if displaylink.exists() and (directory / "DisplayLink.txt").read_bytes() != displaylink.read_bytes():
        raise ValueError("DisplayLink original differs from audited license")
    if copy_to:
        copy_to.mkdir(parents=True, exist_ok=True)
        for name, source in sources.items():
            shutil.copyfile(source, copy_to / name)
        shutil.copyfile(index, copy_to / "THIRD_PARTY.md")
        (copy_to / "THIRD_PARTY_NOTICES.txt").write_text(combined)
        shutil.copyfile(checkout / "BinaryTarget/ghostty-build-provenance.json", copy_to / "ghostty-build-provenance.json")
    if app:
        resources = Path(app) / "Contents/Resources"
        bundled = resources / "Licenses"
        for name in names:
            if (bundled / name).read_bytes() != sources[name].read_bytes():
                raise ValueError(f"Packaged license differs: {name}")
        if (bundled / "THIRD_PARTY.md").read_bytes() != index.read_bytes():
            raise ValueError("Packaged license index differs")
        if (bundled / "THIRD_PARTY_NOTICES.txt").read_text() != combined:
            raise ValueError("Packaged combined notices incomplete or stale")
        if (bundled / "ghostty-build-provenance.json").read_bytes() != (checkout / "BinaryTarget/ghostty-build-provenance.json").read_bytes():
            raise ValueError("Packaged local Ghostty provenance differs")
        check_shell_integrations(resources, directory)
    print(f"License check passed: {len(notices)} audited notices" + (f"; app {app}" if app else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="also validate the packaged .app")
    parser.add_argument("--copy-notices-to", type=Path, help="copy the verified effective notices for packaging")
    args = parser.parse_args()
    try:
        check(args.app, args.copy_notices_to)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"License check failed: {error}", file=sys.stderr)
        sys.exit(1)
