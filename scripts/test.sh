#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_options=(--build-system native --disable-xctest)
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == */CommandLineTools && -d "$developer_dir/SDKs/MacOSX26.sdk" ]]; then
    test_options+=(--sdk "$developer_dir/SDKs/MacOSX26.sdk")
    # Native SwiftPM does not discover CLT's separate Swift Testing framework
    # when compiling against the older SDK. Supply it for compile, link, and run.
    testing_frameworks="$developer_dir/Library/Developer/Frameworks"
    if [[ -d "$testing_frameworks/Testing.framework" ]]; then
        test_options+=(-Xswiftc -F -Xswiftc "$testing_frameworks"
                      -Xlinker -F -Xlinker "$testing_frameworks"
                      -Xlinker -rpath -Xlinker "$testing_frameworks")
    fi
    testing_plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [[ -f "$testing_plugin" ]]; then
        test_options+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
    fi
fi
swift test "${test_options[@]}" "$@"
