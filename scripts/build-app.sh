#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

configuration=debug
should_launch=false
installed_build=false
for argument in "$@"; do
    case "$argument" in
        --release) configuration=release ;;
        --launch) should_launch=true ;;
        --installed) installed_build=true ;;
        *) print -u2 "Usage: $0 [--release] [--launch] [--installed]"; exit 2 ;;
    esac
done

# The installed CLT has a 27 SDK without the new SwiftUI macro plug-in. Its
# included 26 SDK retains native property wrappers and matches our target OS.
# A full Xcode installation keeps its selected SDK and standard macro support.
developer_dir="$(xcode-select -p)"
sdk_arguments=()
if [[ "$developer_dir" == */CommandLineTools && -d "$developer_dir/SDKs/MacOSX26.sdk" ]]; then
    sdk_arguments=(--sdk "$developer_dir/SDKs/MacOSX26.sdk")
fi
build_arguments=(--build-system native "${sdk_arguments[@]}" --configuration "$configuration" -Xswiftc -warnings-as-errors)
if $installed_build; then
    build_arguments+=(-Xswiftc -D -Xswiftc MUSEFRAME_INSTALLED_BUILD)
fi
swift build "${build_arguments[@]}"
binary_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
app_dir="$project_dir/.build/MuseFrame.app"
if [[ -d "$app_dir" ]]; then
    rm -rf -- "$app_dir"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/MuseFrame" "$app_dir/Contents/MacOS/MuseFrame"
cp "$project_dir/MuseFrame/App/Info.plist" "$app_dir/Contents/Info.plist"
# SwiftPM/CLT does not run actool; this bundle uses the ICNS fallback. Xcode
# retains CFBundleIconName and compiles the matching AppIcon asset catalog.
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$app_dir/Contents/Info.plist"
cp "$project_dir/MuseFrame/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

# MuseFrameResources resolves SwiftPM resources from this standard bundle path.
for resource_bundle in "$binary_dir"/*.bundle(N); do
    ditto "$resource_bundle" "$app_dir/Contents/Resources/${resource_bundle:t}"
done

mkdir -p "$app_dir/Contents/Library/LoginItems" "$app_dir/Contents/Library/LaunchAgents"
helper_arguments=(--output "$app_dir/Contents/Library/LoginItems/MuseFrameRotationHelper.app")
if [[ "$configuration" == release ]]; then helper_arguments+=(--release); fi
if $installed_build; then helper_arguments+=(--installed); fi
"$project_dir/scripts/build-helper.sh" "${helper_arguments[@]}"
cp "$project_dir/MuseFrame/Resources/io.museframe.rotation.plist" "$app_dir/Contents/Library/LaunchAgents/io.museframe.rotation.plist"

mkdir -p "$app_dir/Contents/PlugIns"
widget_arguments=(--output "$app_dir/Contents/PlugIns/MuseFrameWidget.appex")
if [[ "$configuration" == release ]]; then widget_arguments+=(--release); fi
if $installed_build; then widget_arguments+=(--installed); fi
"$project_dir/scripts/build-widget.sh" "${widget_arguments[@]}"

# Both nested products are signed before their containing application. Installed
# builds claim the real shared group in all three processes; they still require
# system authorization (or production signing) before desktop acceptance.
app_signing_arguments=(--force --sign -)
if $installed_build; then
    app_signing_arguments+=(--entitlements "$project_dir/MuseFrame/App/MuseFrame.entitlements")
fi
codesign "${app_signing_arguments[@]}" "$app_dir"
codesign --verify --deep --strict "$app_dir"
print "Built $app_dir"
if $should_launch; then
    open "$app_dir"
fi
