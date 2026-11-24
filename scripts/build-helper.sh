#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
helper_output="$project_dir/.build/HelperValidation/MuseFrameRotationHelper.app"
helper_optimization=-Onone
print_sources=false
installed_build=false
helper_sources=(
    MuseFrameHelper/MuseFrameHelper.swift
    MuseFrame/Models/Artwork.swift
    MuseFrame/Services/RotationEngine.swift
    MuseFrame/Services/WallpaperEngine.swift
    MuseFrame/Services/ScreenFitEngine.swift
    MuseFrame/Services/ImageCache.swift
    MuseFrame/Services/DesktopCropRenderer.swift
    MuseFrame/Services/BackgroundRotationRuntime.swift
    MuseFrame/Services/PerformanceDiagnostics.swift
    MuseFrame/Shared/SharedEnvironment.swift
    MuseFrame/Shared/ProcessFileLock.swift
    MuseFrame/Shared/RotationSharedStore.swift
    MuseFrame/Shared/CurrentArtworkSnapshot.swift
    MuseFrame/Shared/MuseFrameDeepLink.swift
    MuseFrame/Shared/MuseFrameResources.swift
    MuseFrame/Shared/BackgroundHelperStatus.swift
    MuseFrame/Shared/WidgetReloadPolicy.swift
    MuseFrame/Shared/RotationSchedule.swift
)
while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || { print -u2 'Missing --output path'; exit 2; }
            helper_output="$2"; shift 2 ;;
        --release) helper_optimization=-O; shift ;;
        --installed) installed_build=true; shift ;;
        --print-sources) print_sources=true; shift ;;
        *) print -u2 "Usage: $0 [--output HELPER.app] [--release] [--installed] [--print-sources]"; exit 2 ;;
    esac
done
if $print_sources; then
    print -l -- "${helper_sources[@]}"
    exit 0
fi
[[ "${helper_output:t}" == MuseFrameRotationHelper.app ]] || { print -u2 'Output must be MuseFrameRotationHelper.app'; exit 2; }
helper_input=()
for helper_source in "${helper_sources[@]}"; do
    [[ -f "$project_dir/$helper_source" ]] || { print -u2 "Missing helper source: $helper_source"; exit 1; }
    helper_input+=("$project_dir/$helper_source")
done

developer_dir="$(xcode-select -p)"
helper_sdk="$(xcrun --sdk macosx --show-sdk-path)"
if [[ "$developer_dir" == */CommandLineTools && -d "$developer_dir/SDKs/MacOSX26.sdk" ]]; then
    helper_sdk="$developer_dir/SDKs/MacOSX26.sdk"
fi
mkdir -p "$helper_output/Contents/MacOS"
cp "$project_dir/MuseFrameHelper/Info.plist" "$helper_output/Contents/Info.plist"
helper_conditions=(-D MUSEFRAME_HELPER)
helper_signing_arguments=(--force --sign -)
if $installed_build; then
    helper_conditions+=(-D MUSEFRAME_INSTALLED_BUILD)
    helper_signing_arguments+=(--entitlements "$project_dir/MuseFrameHelper/MuseFrameHelper.entitlements")
else
    helper_conditions+=(-D MUSEFRAME_LOCAL_BUILD)
fi
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
    -sdk "$helper_sdk" -target "$(uname -m)-apple-macos26.0" \
    "${helper_conditions[@]}" "$helper_optimization" \
    "${helper_input[@]}" -o "$helper_output/Contents/MacOS/MuseFrameRotationHelper"
# Packaging does not launch, register, or install a service. The installed mode
# claims the same group as the host; authorization must be tested separately.
codesign "${helper_signing_arguments[@]}" "$helper_output"
codesign --verify --deep --strict "$helper_output"
print "Built background helper: $helper_output"
