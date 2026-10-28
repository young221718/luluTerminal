#!/usr/bin/env python3
"""Record actual macOS Ghostty build inputs and XCFramework bytes."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def output(*command):
    return subprocess.check_output(command, text=True).strip()


parser = argparse.ArgumentParser()
parser.add_argument('wrapper', type=pathlib.Path)
parser.add_argument('engine', type=pathlib.Path)
parser.add_argument('zig', type=pathlib.Path)
args = parser.parse_args()
wrapper = args.wrapper.resolve()
engine = args.engine.resolve()
xcframework = wrapper / 'BinaryTarget/GhosttyKit.xcframework'
assert xcframework.is_dir(), 'Build and verify XCFramework first'
files = [dict(path=str(p.relative_to(xcframework)), sha256=sha256(p), sizeBytes=p.stat().st_size)
         for p in sorted(xcframework.rglob('*')) if p.is_file()]
archives = []
for archive in sorted(xcframework.rglob('libghostty.a')):
    architectures = []
    for name in output('lipo', '-archs', str(archive)).split():
        with tempfile.TemporaryDirectory(prefix='ghostty-provenance-') as temporary:
            thin = pathlib.Path(temporary) / (name + '.a')
            subprocess.run(['lipo', str(archive), '-thin', name, '-output', str(thin)], check=True)
            load_commands = output('otool', '-l', str(thin))
            minos = sorted(set(re.findall(r'^\s*minos\s+(\S+)', load_commands, re.MULTILINE)))
            assert minos == ['13.0'], f'{name} deployment targets must be13.0, got {minos}'
            architectures.append(dict(name=name, sha256=sha256(thin), minimumDeploymentTargets=minos))
    archives.append(dict(path=str(archive.relative_to(xcframework)), architectures=architectures))
patches = [dict(path=str(p.relative_to(wrapper)), sha256=sha256(p))
           for p in sorted((wrapper / 'Patches/ghostty').iterdir()) if p.suffix in ('.patch', '.sh')]
changed_paths = subprocess.check_output(['git', '-C', str(engine), 'diff', '--name-only', '-z', 'HEAD']).decode().split('\0')
changed_paths += subprocess.check_output(['git', '-C', str(engine), 'ls-files', '--others', '--exclude-standard', '-z']).decode().split('\0')
engine_changes = [dict(path=path, sha256=sha256(engine / path)) for path in sorted(set(filter(None, changed_paths)))]
flags = ['-Dapp-runtime=none', '-Demit-exe=false', '-Demit-xcframework=false',
         '-Demit-macos-app=false', '-Demit-docs=false', '-Dsentry=false',
         '-Dcustom-shaders=false', '-Dinspector=false', '-Di18n=false']
provenance = dict(
    schemaVersion=1,
    engine=dict(version='1.4.0', revision=output('git', '-C', str(engine), 'rev-parse', 'HEAD')),
    wrapper=dict(revision=output('git', '-C', str(wrapper), 'rev-parse', 'HEAD')),
    toolchain=dict(zigVersion=output(str(args.zig), 'version'), zigSha256=sha256(args.zig),
                   xcodeVersion=output('xcodebuild', '-version'), sdkVersion=output('xcrun', '--show-sdk-version')),
    build=dict(platform='macos', architectures=['arm64', 'x86_64'], optimize='fast', parallelJobs=2, flags=flags),
    patches=patches,
    engineChanges=engine_changes,
    buildInputs=[dict(path=name, sha256=sha256(wrapper / name)) for name in
                 ('Ghostty.ref', 'Ghostty.build', 'Script/build-ghostty.sh', 'Script/build-platform.sh',
                  'Script/merge-xcframework.sh', 'Script/verify-xcframework.sh')],
    artifact=dict(path='BinaryTarget/GhosttyKit.xcframework', files=files, archives=archives),
    validation=dict(testOnlyNoopRuntimeShimExcluded=True,
                    note='none.App.wakeup test-harness shim is excluded; test receipts are separate build evidence.'),
)
assert provenance['engine']['revision'] == '83fb95624b0439ee660c2679b43b38c8b63769cd'
assert provenance['wrapper']['revision'] == '5b9cb63d83e687b4a66d6c3a3c2a840341c576d9'
assert provenance['toolchain']['zigVersion'] == '0.17.0'
assert {a['name'] for arc in archives for a in arc['architectures']} == {'arm64', 'x86_64'}
none_original = subprocess.check_output(['git', '-C', str(engine), 'show', 'HEAD:src/apprt/none.zig'])
assert (engine / 'src/apprt/none.zig').read_bytes() == none_original, 'Remove test-only shim before production build'
path = wrapper / 'BinaryTarget/ghostty-build-provenance.json'
path.write_text(json.dumps(provenance, indent=2) + '\n')
print(path)
