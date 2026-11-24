#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
widget_output="$project_dir/.build/WidgetValidation/MuseFrameWidget.appex"
widget_optimization=-Onone
installed_build=false
while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || { print -u2 'Missing --output path'; exit 2; }
            widget_output="$2"; shift 2 ;;
        --release) widget_optimization=-O; shift ;;
        --installed) installed_build=true; shift ;;
        *) print -u2 "Usage: $0 [--output MuseFrameWidget.appex] [--release] [--installed]"; exit 2 ;;
    esac
done
[[ "${widget_output:t}" == MuseFrameWidget.appex ]] || { print -u2 'Output must be MuseFrameWidget.appex'; exit 2; }
widget_output="${widget_output:A}"

developer_dir="$(xcode-select -p)"
widget_sdk="$(xcrun --sdk macosx --show-sdk-path)"
if [[ "$developer_dir" == */CommandLineTools && -d "$developer_dir/SDKs/MacOSX26.sdk" ]]; then
    widget_sdk="$developer_dir/SDKs/MacOSX26.sdk"
fi
widget_conditions=(-D MUSEFRAME_WIDGET)
if $installed_build; then
    widget_conditions+=(-D MUSEFRAME_INSTALLED_BUILD)
else
    widget_conditions+=(-D MUSEFRAME_LOCAL_BUILD)
fi

mkdir -p "${widget_output:h}"
widget_workdir="$(mktemp -d "${widget_output:h}/.MuseFrameWidget.XXXXXX")"
trap 'rm -rf -- "$widget_workdir"' EXIT
widget_staging="$widget_workdir/MuseFrameWidget.appex"
mkdir -p "$widget_staging/Contents/MacOS"

# Xcode expands these variables while processing Info.plist. CLT packaging must
# do that explicitly; an unresolved executable name cannot be registered.
python3 - "$project_dir/MuseFrameWidget/Info.plist" "$widget_staging/Contents/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

values = {
    "PRODUCT_BUNDLE_IDENTIFIER": "io.museframe.app.widget",
    "EXECUTABLE_NAME": "MuseFrameWidget",
    "PRODUCT_NAME": "MuseFrameWidget",
}

def expanded(value):
    if isinstance(value, str):
        for key, replacement in values.items():
            value = value.replace(f"$({key})", replacement).replace(f"${{{key}}}", replacement)
        if "$(" in value or "${" in value:
            raise ValueError(f"Unresolved Widget Info.plist variable: {value}")
        return value
    if isinstance(value, dict):
        return {key: expanded(item) for key, item in value.items()}
    if isinstance(value, list):
        return [expanded(item) for item in value]
    return value

info = expanded(plistlib.loads(Path(sys.argv[1]).read_bytes()))
info["CFBundleInfoDictionaryVersion"] = "6.0"
info["CFBundleSupportedPlatforms"] = ["MacOSX"]
info["LSMinimumSystemVersion"] = "26.0"
assert info["CFBundlePackageType"] == "XPC!"
assert info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
Path(sys.argv[2]).write_bytes(plistlib.dumps(info, sort_keys=False))
PY

xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors -application-extension \
    -module-name MuseFrameWidget -sdk "$widget_sdk" -target "$(uname -m)-apple-macosx26.0" \
    "${widget_conditions[@]}" "$widget_optimization" \
    "$project_dir/MuseFrame/Shared/CurrentArtworkSnapshot.swift" \
    "$project_dir/MuseFrame/Shared/SharedEnvironment.swift" \
    "$project_dir/MuseFrame/Shared/ProcessFileLock.swift" \
    "$project_dir/MuseFrame/Shared/MuseFrameDeepLink.swift" \
    "$project_dir/MuseFrame/Shared/WidgetReloadPolicy.swift" \
    "$project_dir/MuseFrame/Shared/RotationSchedule.swift" \
    "$project_dir/MuseFrame/Shared/WidgetTimelineSnapshot.swift" \
    "$project_dir/MuseFrameWidget/MuseFrameWidget.swift" \
    -o "$widget_staging/Contents/MacOS/MuseFrameWidget"

# Sign the complete extension, binding its processed Info.plist and entitlements.
# Ad-hoc signing permits local packaging checks; system admission and group
# authorization are separate installation tests, not claims made by this script.
codesign --force --sign - --entitlements "$project_dir/MuseFrameWidget/MuseFrameWidget.entitlements" "$widget_staging"
codesign --verify --strict "$widget_staging"
if [[ -e "$widget_output" ]]; then rm -rf -- "$widget_output"; fi
mv "$widget_staging" "$widget_output"
print "Built Widget extension: $widget_output"
print 'No extension registration, installation, or desktop Widget validation performed.'
