#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
developer_dir=$(xcode-select -p)
if swift_executable=$(xcrun --find swift 2>/dev/null); then
  :
else
  swift_executable="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
fi
swift_host="$(dirname "$(dirname "$swift_executable")")/lib/swift/host"
macos_sdk="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

exec "$swift_executable" -sdk "$macos_sdk" -I "$swift_host" -L "$swift_host" \
  -lSwiftParser -lSwiftSyntax -Xlinker -rpath -Xlinker "$swift_host" \
  "$script_dir/swiftdata-repository-declarations.swift" "$1"
