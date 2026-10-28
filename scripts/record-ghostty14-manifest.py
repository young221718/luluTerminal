#!/usr/bin/env python3
"""Write a candidate local-build audit record for review, without editing source."""
import argparse
import hashlib
import json
from pathlib import Path


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("package", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / "docs/licenses/manifest-ghostty14.json").read_text())
provenance_bytes = (args.package / "BinaryTarget/ghostty-build-provenance.json").read_bytes()
provenance = json.loads(provenance_bytes)
if provenance["engine"]["revision"] != manifest["ghostty_revision"] or provenance["wrapper"]["revision"] != manifest["libghostty_spm_revision"]:
    raise SystemExit("Build revisions differ from the reviewed source policy")
paths = [args.package / "Package.swift", args.package / "Ghostty.ref"]
paths += [p for target in ["GhosttyKit", "GhosttyTerminal"] for p in (args.package / "Sources" / target).rglob("*") if p.is_file()]
manifest["local_wrapper_files"] = [{"path": p.relative_to(args.package).as_posix(), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(paths)]
manifest["local_provenance_sha256"] = hashlib.sha256(provenance_bytes).hexdigest()
manifest["local_build_policy"] = {key: provenance[key] for key in ["patches", "buildInputs", "engineChanges", "build"]}
with args.output.open("x") as handle:
    handle.write(json.dumps(manifest, indent=2) + "\n")
print(args.output)
