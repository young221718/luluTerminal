#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
test_frameworks="$developer_dir/Library/Developer/Frameworks"
testing_plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -d "$test_frameworks/Testing.framework" ] && [ -f "$testing_plugin" ]; then
    # Command Line Tools includes Testing but SwiftBuild may omit its macro
    # plugin on incremental builds. Native SwiftPM is repeatable here.
    exec swift test --build-system native \
      -Xswiftc -F -Xswiftc "$test_frameworks" \
      -Xswiftc -load-resolved-plugin \
      -Xswiftc "$testing_plugin#$developer_dir/usr/bin/swift-plugin-server#TestingMacros" \
      -Xlinker "-F$test_frameworks" \
      -Xlinker -rpath -Xlinker "$test_frameworks" "$@"
fi
exec swift test "$@"
