#!/bin/zsh

set -euo pipefail
setopt typesetsilent

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
output_directory="$repository_directory/Marketing/Screenshots/Captures"
derived_data="$repository_directory/.build/mobile-marketing-screenshots"
marketing_xctestrun="$derived_data/Build/Products/Marketing-TFI.xctestrun"
marketing_scenes="${TERMIND_MARKETING_SCENES:-}"
marketing_devices="${TERMIND_MARKETING_DEVICES:-iphone,ipad}"
marketing_runtime="${TERMIND_MARKETING_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"

case "$marketing_runtime" in
    com.apple.CoreSimulator.SimRuntime.iOS-27-*) ;;
    *)
        print -u2 "Marketing screenshots require an iOS/iPadOS 27 runtime: $marketing_runtime"
        exit 64
        ;;
esac

expected_capture_count() {
    if [[ -z "$marketing_scenes" ]]; then
        print 5
        return
    fi
    local -a scenes
    scenes=("${(@s:,:)marketing_scenes}")
    local scene_count="${#scenes}"
    print "$scene_count"
}

find_device() {
    local name="$1"
    xcrun simctl list devices available -j \
        | jq -r --arg name "$name" --arg runtime "$marketing_runtime" \
            '.devices[$runtime][]? | select(.name == $name) | .udid' \
        | head -n 1
}

run_capture() {
    local name="$1"
    local language="$2"
    local device_id
    device_id="$(find_device "$name")"
    if [[ -z "$device_id" ]]; then
        print -u2 "Required simulator is unavailable: $name ($marketing_runtime)"
        exit 69
    fi

    xcrun simctl boot "$device_id" 2>/dev/null || true
    xcrun simctl bootstatus "$device_id" -b
    if [[ "$name" == iPad* ]]; then
        xcrun devicectl device orientation set --device "$device_id" landscapeLeft >/dev/null
    fi
    xcrun simctl status_bar "$device_id" override \
        --time '9:41' --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
    local region apple_locale
    case "$language" in
        en) region=US; apple_locale=en_US ;;
        zh-Hans) region=CN; apple_locale=zh_CN ;;
        zh-Hant) region=TW; apple_locale=zh_TW ;;
    esac
    local capture_id="$(uuidgen)"
    local localized_xctestrun="$derived_data/Build/Products/Marketing-TFI-$language.xctestrun"
    cp "$marketing_xctestrun" "$localized_xctestrun"
    /usr/libexec/PlistBuddy \
        -c "Add :TFITests:EnvironmentVariables:TERMIND_MARKETING_LOCALE string $language" \
        -c "Add :TFITests:EnvironmentVariables:TERMIND_MARKETING_CAPTURE_ID string $capture_id" \
        -c "Set :TFITests:TestLanguage $language" \
        -c "Set :TFITests:TestRegion $region" \
        -c 'Add :TFITests:CommandLineArguments:0 string -AppleLanguages' \
        -c "Add :TFITests:CommandLineArguments:1 string ($language)" \
        -c 'Add :TFITests:CommandLineArguments:2 string -AppleLocale' \
        -c "Add :TFITests:CommandLineArguments:3 string $apple_locale" \
        "$localized_xctestrun"
    local test_log="$derived_data/${device_id}-$language-capture.log"
    xcodebuild \
        -xctestrun "$localized_xctestrun" \
        -destination "id=$device_id" \
        -only-testing:TFITests/MobileMarketingScreenshotTests \
        test-without-building > "$test_log" 2>&1 &
    local test_pid=$!
    local captures=0
    local last_token=""
    local capture_directory="$derived_data/captures/$device_id-$language"
    local -a captured_paths destinations
    mkdir -p "$capture_directory"

    while kill -0 "$test_pid" 2>/dev/null; do
        local app_container
        app_container="$(xcrun simctl get_app_container "$device_id" com.akinokaede.termind data 2>/dev/null || true)"
        local ready="$app_container/Documents/marketing-capture-control/ready"
        if [[ -n "$app_container" && -f "$ready" ]]; then
            local feature device locale token request_capture_id
            IFS=$'\t' read -r feature device locale token request_capture_id < "$ready"
            if [[ "$request_capture_id" == "$capture_id" && -n "$token" && "$token" != "$last_token" ]]; then
                local destination="$output_directory/$feature/$device-$locale.png"
                local captured="$capture_directory/$feature.png"
                if [[ "$device" == "ipad" ]]; then
                    rm -f "$captured"
                    xcrun devicectl device capture screenshot \
                        --device "$device_id" \
                        --destination "$captured" >/dev/null
                    local width height
                    width="$(sips -g pixelWidth "$captured" | awk '/pixelWidth/ { print $2 }')"
                    height="$(sips -g pixelHeight "$captured" | awk '/pixelHeight/ { print $2 }')"
                    if [[ "$width" != "2752" || "$height" != "2064" ]]; then
                        print -u2 "Unexpected iPad screenshot dimensions: ${width}x${height}"
                        kill "$test_pid" 2>/dev/null || true
                        wait "$test_pid" 2>/dev/null || true
                        xcrun simctl status_bar "$device_id" clear
                        exit 70
                    fi
                else
                    xcrun simctl io "$device_id" screenshot --type=png "$captured" >/dev/null
                fi
                captured_paths+=("$captured")
                destinations+=("$destination")
                touch "$app_container/Documents/marketing-capture-control/ack-$token"
                last_token="$token"
                (( captures += 1 ))
                print "Captured $feature/$device-$locale.png"
            fi
        fi
        sleep 0.05
    done
    if ! wait "$test_pid"; then
        xcrun simctl status_bar "$device_id" clear
        tail -n 80 "$test_log" >&2
        exit 70
    fi
    xcrun simctl status_bar "$device_id" clear
    local expected
    expected="$(expected_capture_count)"
    if [[ "$captures" -ne "$expected" ]]; then
        print -u2 "Expected $expected captures for $name ($language), received $captures. See $test_log"
        exit 70
    fi
    for (( index = 1; index <= ${#captured_paths}; index++ )); do
        mkdir -p "${destinations[$index]:h}"
        cp "$captured_paths[$index]" "$destinations[$index]"
    done
}

mkdir -p "$output_directory"
if [[ ",$marketing_devices," == *,iphone,* ]]; then
    build_device_name="iPhone 17 Pro Max"
elif [[ ",$marketing_devices," == *,ipad,* ]]; then
    build_device_name="iPad Pro 13-inch (M5)"
else
    print -u2 "Select at least one marketing device: iphone,ipad"
    exit 64
fi
build_device_id="$(find_device "$build_device_name")"
if [[ -z "$build_device_id" ]]; then
    print -u2 "Required simulator is unavailable: $build_device_name ($marketing_runtime)"
    exit 69
fi
xcodebuild \
    -project "$repository_directory/Termind.xcodeproj" \
    -scheme TFI \
    -destination "id=$build_device_id" \
    -onlyUsePackageVersionsFromResolvedFile \
    -derivedDataPath "$derived_data" \
    build-for-testing

generated_xctestrun="$(find "$derived_data/Build/Products" -maxdepth 1 -name 'TFI_*.xctestrun' -print -quit)"
if [[ -z "$generated_xctestrun" ]]; then
    print -u2 "Unable to find the generated TFI xctestrun file."
    exit 70
fi
cp -f "$generated_xctestrun" "$marketing_xctestrun"
/usr/libexec/PlistBuddy \
    -c 'Add :TFITests:EnvironmentVariables:TERMIND_MARKETING_SCREENSHOTS string 1' \
    "$marketing_xctestrun"
/usr/libexec/PlistBuddy \
    -c 'Add :TFITests:EnvironmentVariables:TERMIND_MARKETING_SYSTEM_CAPTURE string 1' \
    "$marketing_xctestrun"
if [[ -n "$marketing_scenes" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Add :TFITests:EnvironmentVariables:TERMIND_MARKETING_SCENES string $marketing_scenes" \
        "$marketing_xctestrun"
fi

if [[ ",$marketing_devices," == *,iphone,* ]]; then
    for language in en zh-Hans zh-Hant; do
        run_capture "iPhone 17 Pro Max" "$language"
    done
fi
if [[ ",$marketing_devices," == *,ipad,* ]]; then
    for language in en zh-Hans zh-Hant; do
        run_capture "iPad Pro 13-inch (M5)" "$language"
    done
fi

print "Marketing screenshots written to $output_directory"
