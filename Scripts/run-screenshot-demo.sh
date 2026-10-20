#!/bin/zsh
# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

usage() {
    print -u2 "Usage: Scripts/run-screenshot-demo.sh <hosts|workspace|agent|command|metrics|metrics-detail|app-settings> <en|ja|ko|de|fr|zh-Hans|zh-Hant>"
}

if (( $# != 2 )); then
    usage
    exit 64
fi

scene="$1"
language="$2"

case "$scene" in
    hosts|workspace|agent|command|metrics|metrics-detail|app-settings) ;;
    *)
        print -u2 "Unknown Demo scene: $scene"
        usage
        exit 64
        ;;
esac

case "$language" in
    en)
        apple_language="en"
        apple_locale="en_US"
        ;;
    ja)
        apple_language="ja"
        apple_locale="ja_JP"
        ;;
    ko)
        apple_language="ko"
        apple_locale="ko_KR"
        ;;
    de)
        apple_language="de"
        apple_locale="de_DE"
        ;;
    fr)
        apple_language="fr"
        apple_locale="fr_FR"
        ;;
    zh-Hans)
        apple_language="zh-Hans"
        apple_locale="zh-Hans"
        ;;
    zh-Hant)
        apple_language="zh-Hant"
        apple_locale="zh-Hant"
        ;;
    *)
        print -u2 "Unknown Demo language: $language"
        usage
        exit 64
        ;;
esac

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
derived_data="$repository_directory/.build/screenshot-demo"
application="$derived_data/Build/Products/Debug/Termind.app"

xcodebuild \
    -project "$repository_directory/Termind.xcodeproj" \
    -scheme TFM \
    -configuration Debug \
    -destination 'platform=macOS' \
    -onlyUsePackageVersionsFromResolvedFile \
    -derivedDataPath "$derived_data" \
    build

open -n "$application" --args "--termind-demo=$scene:$language" \
    -AppleLanguages "($apple_language)" -AppleLocale "$apple_locale"
