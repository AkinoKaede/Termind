#!/bin/zsh

set -euo pipefail
setopt typesetsilent

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
derived_data="$repository_directory/.build/mac-marketing-tests"
products="$derived_data/Build/Products"
backup_directory="$repository_directory/.build/screenshot-backups/$(date +%Y%m%d-%H%M%S)"
output_directory="$repository_directory/Marketing/Screenshots/Captures"
marketing_scenes="${TERMIND_MAC_MARKETING_SCENES:-workspace}"
marketing_locales="${TERMIND_MAC_MARKETING_LOCALES:-en,zh-Hans,zh-Hant}"
local_test_pid=""

macos_version="$(sw_vers -productVersion)"
if [[ "$macos_version" != 27.* ]]; then
    print -u2 "Mac marketing screenshots require macOS 27.x; current version is $macos_version"
    exit 69
fi

cleanup() {
    if [[ -n "$local_test_pid" ]]; then
        kill "$local_test_pid" 2>/dev/null || true
        wait "$local_test_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

for scene in ${(s:,:)marketing_scenes}; do
    case "$scene" in
        hosts|workspace|agent|command|metrics) ;;
        *) print -u2 "Unsupported marketing scene: $scene"; exit 64 ;;
    esac
done
for language in ${(s:,:)marketing_locales}; do
    case "$language" in
        en|zh-Hans|zh-Hant) ;;
        *) print -u2 "Unsupported marketing locale: $language"; exit 64 ;;
    esac
done

mkdir -p "$derived_data"
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
    local scene="$1"
    local language="$2"
    local region asset_locale apple_locale feature prefix
    local width=2360 height=1480
    case "$language" in
        en) region=US; asset_locale=en; apple_locale=en_US ;;
        zh-Hans) region=CN; asset_locale=zh-hans; apple_locale=zh_CN ;;
        zh-Hant) region=TW; asset_locale=zh-hant; apple_locale=zh_TW ;;
    esac
    prefix=mac
    case "$scene" in
        hosts) feature=vault ;;
        workspace) feature=workspace ;;
        agent) feature=assistant ;;
        command) feature=command-generator; width=2044; height=1280 ;;
        metrics) feature=metrics; prefix=mac-overview ;;
    esac
    local xctestrun="$products/Marketing-TFM-$scene-$asset_locale.xctestrun"
    local test_log="$derived_data/$scene-$asset_locale-capture.log"
    local destination="$output_directory/$feature/$prefix-$asset_locale.png"
    local captured="$derived_data/$scene-$asset_locale.png"

    cp "$source_xctestrun" "$xctestrun"
    /usr/libexec/PlistBuddy \
        -c 'Add :TFMTests:EnvironmentVariables:TERMIND_MAC_MARKETING_SCREENSHOTS string 1' \
        -c "Set :TFMTests:TestLanguage $language" \
        -c "Set :TFMTests:TestRegion $region" \
        -c "Add :TFMTests:CommandLineArguments:0 string --termind-demo=$scene:$language" \
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
    local_test_pid=$!
    local ready_payload=""

    for _ in {1..2400}; do
        ready_payload="$(
            rg -o 'TERMIND_MAC_MARKETING_READY .*' "$test_log" \
                | tail -n 1 \
                | sed 's/TERMIND_MAC_MARKETING_READY //' \
                || true
        )"
        [[ -n "$ready_payload" ]] && break
        if ! kill -0 "$local_test_pid" 2>/dev/null; then
            tail -n 100 "$test_log" >&2
            exit 70
        fi
        sleep 0.1
    done
    if [[ -z "$ready_payload" ]]; then
        tail -n 100 "$test_log" >&2
        exit 70
    fi

    local captured_scene captured_language window_id token active key
    IFS=$'\t' read -r captured_scene captured_language window_id token active key <<< "$ready_payload"
    if [[ "$captured_scene" != "$scene" || "$captured_language" != "$language" || "$active" != active || "$key" != key ]]; then
        print -u2 "Capture window was not ready and focused: $ready_payload"
        exit 70
    fi

    screencapture -l "$window_id" -o "$captured"
    if ! wait "$local_test_pid"; then
        tail -n 100 "$test_log" >&2
        exit 70
    fi
    local_test_pid=""

    local dimensions="$(identify -format '%wx%h' "$captured")"
    if [[ "$dimensions" == "$((width + 4))x$((height + 4))" ]]; then
        sips -c "$height" "$width" "$captured" >/dev/null
        dimensions="$(identify -format '%wx%h' "$captured")"
    fi
    if [[ "$dimensions" != "${width}x${height}" ]]; then
        print -u2 "Unexpected $scene dimensions for $asset_locale: $dimensions"
        exit 70
    fi
    mkdir -p "${destination:h}" "$backup_directory/$feature"
    if [[ -f "$destination" ]]; then
        cp "$destination" "$backup_directory/$feature/${destination:t}"
    fi
    cp "$captured" "$destination"
    print "Captured focused $scene -> ${destination#$repository_directory/}"
}

for scene in ${(s:,:)marketing_scenes}; do
    for language in ${(s:,:)marketing_locales}; do
        capture "$scene" "$language"
    done
done

print "Previous captures backed up in ${backup_directory#$repository_directory/}"
