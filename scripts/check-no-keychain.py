#!/usr/bin/env python3
"""Reject obsolete password helpers and Keychain calls in the shipped app."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
args = parser.parse_args()
binary = args.app / "Contents/MacOS/InfraTerminal"
if not binary.is_file():
    parser.error(f"App executable is missing: {binary}")

obsolete = {"luluTerminalAskPass", "luluTerminalKeychain"}
found_helpers = sorted(p.name for p in args.app.rglob("*") if p.name in obsolete)
symbols = subprocess.run(["/usr/bin/nm", "-u", str(binary)], check=True,
                         capture_output=True, text=True).stdout
forbidden = {"_SecItemAdd", "_SecItemCopyMatching", "_SecItemUpdate", "_SecItemDelete",
             "_SecKeychainSetUserInteractionAllowed", "_SecAccessCreate",
             "_SecTrustedApplicationCreateFromPath", "_SecKeychainItemSetAccess",
             "_SecKeychainItemCopyAccess"}
found_symbols = sorted({line.split()[-1] for line in symbols.splitlines() if line.split()} & forbidden)
if found_helpers or found_symbols:
    raise SystemExit(f"Keychain removal check failed: helpers={found_helpers}, symbols={found_symbols}")
print("No password helpers or Keychain API imports in app executable.")
