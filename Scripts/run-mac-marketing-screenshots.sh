#!/bin/zsh

set -euo pipefail
setopt typesetsilent

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
derived_data="$repository_directory/.build/mac-marketing-tests"
products="$derived_data/Build/Products"
backup_directory="$repository_directory/.build/screenshot-backups/$(date +%Y%m%d-%H%M%S)"
output_directory="$repository_directory/Marketing/Screenshots/Captures/workspace"

xcodebuild \
    -project "$repository_directory/Termind.xcodeproj" \
    -scheme TFM \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -onlyUsePackageVersionsFromResolvedFile \
    -derivedDataPath "$derived_data" \
    build-for-testing > "$derived_data-build.log" 2>&1

source_xctestrun="$(find "$products" -maxdepth 1 -name 'TFM_*.xctestrun' -print -quit)"
if [[ -z "$source_xctestrun" ]]; then
    print -u2 "Unable to find the generated TFM xctestrun file."
    exit 70
fi

capture() {
    local language="$1"
    local region="$2"
    local asset_locale="$3"
    local apple_locale="$4"
    local xctestrun="$products/Marketing-TFM-$asset_locale.xctestrun"
    local test_log="$derived_data/workspace-$asset_locale-capture.log"
    local destination="$output_directory/mac-$asset_locale.png"

    cp "$source_xctestrun" "$xctestrun"
    /usr/libexec/PlistBuddy \
        -c 'Add :TFMTests:EnvironmentVariables:TERMIND_MAC_MARKETING_SCREENSHOTS string 1' \
        -c "Add :TFMTests:EnvironmentVariables:TERMIND_MAC_MARKETING_LOCALE string $language" \
        -c "Set :TFMTests:TestLanguage $language" \
        -c "Set :TFMTests:TestRegion $region" \
        -c "Add :TFMTests:CommandLineArguments:0 string --termind-demo=workspace:$language" \
        -c 'Add :TFMTests:CommandLineArguments:1 string -AppleLanguages' \
        -c "Add :TFMTests:CommandLineArguments:2 string ($language)" \
        -c 'Add :TFMTests:CommandLineArguments:3 string -AppleLocale' \
        -c "Add :TFMTests:CommandLineArguments:4 string $apple_locale" \
        "$xctestrun"

    : > "$test_log"
    xcodebuild \
        -xctestrun "$xctestrun" \
        -destination 'platform=macOS,arch=arm64' \
        -only-testing:TFMTests/MacMarketingScreenshotTests \
        test-without-building > "$test_log" 2>&1 &
    local test_pid=$!
    local ready_path=""

    for _ in {1..300}; do
        ready_path="$(
            rg -o 'TERMIND_MAC_MARKETING_READY .*' "$test_log" \
                | tail -n 1 \
                | sed 's/TERMIND_MAC_MARKETING_READY //' \
                || true
        )"
        [[ -n "$ready_path" && -f "$ready_path" ]] && break
        if ! kill -0 "$test_pid" 2>/dev/null; then
            tail -n 100 "$test_log" >&2
            exit 70
        fi
        sleep 0.1
    done
    if [[ -z "$ready_path" || ! -f "$ready_path" ]]; then
        kill "$test_pid" 2>/dev/null || true
        tail -n 100 "$test_log" >&2
        exit 70
    fi

    local feature captured_language window_id token active key
    IFS=$'\t' read -r feature captured_language window_id token active key < "$ready_path"
    if [[ "$feature" != workspace || "$captured_language" != "$language" || "$active" != active || "$key" != key ]]; then
        print -u2 "Capture window was not ready and focused: $(<"$ready_path")"
        exit 70
    fi

    mkdir -p "$output_directory" "$backup_directory"
    if [[ -f "$destination" ]]; then
        cp "$destination" "$backup_directory/${destination:t}"
    fi
    screencapture -l "$window_id" -o "$destination"
    touch "${ready_path:h}/ack-$token"
    wait "$test_pid"

    local dimensions="$(identify -format '%wx%h' "$destination")"
    if [[ "$dimensions" == 2364x1484 ]]; then
        sips -c 1480 2360 "$destination" >/dev/null
        dimensions="$(identify -format '%wx%h' "$destination")"
    fi
    if [[ "$dimensions" != 2360x1480 ]]; then
        print -u2 "Unexpected Workspace dimensions for $asset_locale: $dimensions"
        exit 70
    fi
    print "Captured focused Workspace -> ${destination#$repository_directory/}"
}

capture en US en en_US
capture zh-Hans CN zh-hans zh_CN
capture zh-Hant TW zh-hant zh_TW

print "Previous raw Workspace captures backed up in ${backup_directory#$repository_directory/}"
