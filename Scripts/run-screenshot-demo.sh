#!/bin/zsh

set -euo pipefail

usage() {
    print -u2 "Usage: Scripts/run-screenshot-demo.sh <hosts|workspace|agent|command> <en|zh>"
}

if (( $# != 2 )); then
    usage
    exit 64
fi

scene="$1"
language="$2"

case "$scene" in
    hosts|workspace|agent|command) ;;
    *)
        print -u2 "Unknown Demo scene: $scene"
        usage
        exit 64
        ;;
esac

case "$language" in
    en|zh) ;;
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
    -scheme Termind \
    -configuration Debug \
    -derivedDataPath "$derived_data" \
    build

open -n "$application" --args "--termind-demo=$scene:$language"
