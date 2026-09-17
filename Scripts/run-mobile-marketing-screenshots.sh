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

expected_capture_count() {
    if [[ -z "$marketing_scenes" ]]; then
        print 15
        return
    fi
    local -a scenes
    scenes=("${(@s:,:)marketing_scenes}")
    local scene_count="${#scenes}"
    print "$((scene_count * 3))"
}

find_device() {
    local name="$1"
    xcrun simctl list devices available -j \
        | jq -r --arg name "$name" '.devices[][] | select(.name == $name) | .udid' \
        | head -n 1
}

set_simulator_orientation() {
    local name="$1"
    local orientation="$2"
    osascript - "$name" "$orientation" <<'APPLESCRIPT'
on run arguments
    set deviceName to item 1 of arguments
    set targetOrientation to item 2 of arguments
    tell application "Simulator" to activate
    tell application "System Events"
        tell process "Simulator"
            repeat with candidate in menu items of menu 1 of menu bar item "Window" of menu bar 1
                if name of candidate starts with deviceName then
                    click candidate
                    exit repeat
                end if
            end repeat
            delay 0.4
            click menu item targetOrientation of menu 1 of menu item "Orientation" of menu 1 of menu bar item "Device" of menu bar 1
        end tell
    end tell
end run
APPLESCRIPT
    sleep 1
}

run_capture() {
    local name="$1"
    local device_id
    device_id="$(find_device "$name")"
    if [[ -z "$device_id" ]]; then
        print -u2 "Required simulator is unavailable: $name"
        exit 69
    fi

    xcrun simctl boot "$device_id" 2>/dev/null || true
    xcrun simctl bootstatus "$device_id" -b
    if [[ "$name" == iPad* ]]; then
        xcrun devicectl device orientation set --device "$device_id" landscapeLeft >/dev/null
    elif pgrep -x Simulator >/dev/null; then
        set_simulator_orientation "$name" "Portrait"
    fi
    xcrun simctl status_bar "$device_id" override \
        --time '9:41' --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
    local test_log="$derived_data/${device_id}-capture.log"
    xcodebuild \
        -xctestrun "$marketing_xctestrun" \
        -destination "id=$device_id" \
        -only-testing:TFITests/MobileMarketingScreenshotTests \
        test-without-building > "$test_log" 2>&1 &
    local test_pid=$!
    local captures=0
    local last_token=""

    while kill -0 "$test_pid" 2>/dev/null; do
        local app_container
        app_container="$(xcrun simctl get_app_container "$device_id" com.akinokaede.termind data 2>/dev/null || true)"
        local ready="$app_container/Documents/marketing-capture-control/ready"
        if [[ -n "$app_container" && -f "$ready" ]]; then
            local feature device locale token
            IFS=$'\t' read -r feature device locale token < "$ready"
            if [[ -n "$token" && "$token" != "$last_token" ]]; then
                local destination="$output_directory/$feature/$device-$locale.png"
                mkdir -p "${destination:h}"
                if [[ "$device" == "ipad" ]]; then
                    rm -f "$destination"
                    xcrun devicectl device capture screenshot \
                        --device "$device_id" \
                        --destination "$destination" >/dev/null
                    local width height
                    width="$(sips -g pixelWidth "$destination" | awk '/pixelWidth/ { print $2 }')"
                    height="$(sips -g pixelHeight "$destination" | awk '/pixelHeight/ { print $2 }')"
                    if [[ "$width" != "2752" || "$height" != "2064" ]]; then
                        print -u2 "Unexpected iPad screenshot dimensions: ${width}x${height}"
                        kill "$test_pid" 2>/dev/null || true
                        wait "$test_pid" 2>/dev/null || true
                        xcrun simctl status_bar "$device_id" clear
                        exit 70
                    fi
                else
                    xcrun simctl io "$device_id" screenshot --type=png "$destination" >/dev/null
                fi
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
        print -u2 "Expected $expected captures for $name, received $captures. See $test_log"
        exit 70
    fi
}

mkdir -p "$output_directory"
build_device_id="$(find_device "iPhone 17 Pro Max")"
if [[ -z "$build_device_id" ]]; then
    print -u2 "Required simulator is unavailable: iPhone 17 Pro Max"
    exit 69
fi
xcodebuild \
    -project "$repository_directory/Termind.xcodeproj" \
    -scheme TFI \
    -destination "id=$build_device_id" \
    -onlyUsePackageVersionsFromResolvedFile \
    -derivedDataPath "$derived_data" \
    EXCLUDED_SOURCE_FILE_NAMES=MobileNavigationParityTests.swift \
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
    run_capture "iPhone 17 Pro Max"
fi
if [[ ",$marketing_devices," == *,ipad,* ]]; then
    run_capture "iPad Pro 13-inch (M5)"
fi

print "Marketing screenshots written to $output_directory"
