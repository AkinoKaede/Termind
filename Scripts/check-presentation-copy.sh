#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
swift_host="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/host"

exec xcrun swift -I "$swift_host" -L "$swift_host" \
  -lSwiftParser -lSwiftSyntax -Xlinker -rpath -Xlinker "$swift_host" \
  "$script_dir/check-presentation-copy.swift" "$script_dir/.."
