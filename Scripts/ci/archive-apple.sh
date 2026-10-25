#!/bin/bash
# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail
umask 077

: "${APPLE_CI_DIR:?Signing environment is not prepared}"
: "${BUILD_VERSION:?Version is required}"
: "${BUILD_PLATFORM:?Platform is required}"

case "$BUILD_PLATFORM" in
  iOS)
    scheme=TFI
    destination='generic/platform=iOS'
    ;;
  macOS)
    scheme=TFM
    destination='generic/platform=macOS'
    ;;
  *)
    printf 'Unsupported platform\n' >&2
    exit 1
    ;;
esac

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

# Use the repository's version rules, including the embedded Widget version.
python3 Scripts/bump-version.py "$BUILD_VERSION"
key_id="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["key_id"])' "$APPLE_CI_DIR/authentication.json")"
issuer="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["issuer"])' "$APPLE_CI_DIR/authentication.json")"
authentication=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$APPLE_CI_DIR/AuthKey.p8"
  -authenticationKeyID "$key_id"
  -authenticationKeyIssuerID "$issuer"
)

# Never dump build settings or publish raw logs containing service configuration.
xcodebuild -quiet \
  -project Termind.xcodeproj \
  -scheme "$scheme" \
  -configuration Release \
  -destination "$destination" \
  -onlyUsePackageVersionsFromResolvedFile \
  -derivedDataPath "$APPLE_CI_DIR/DerivedData" \
  -clonedSourcePackagesDirPath "$APPLE_CI_DIR/DerivedData/SourcePackages" \
  -archivePath "$APPLE_CI_DIR/$scheme.xcarchive" \
  "${authentication[@]}" \
  archive

# Upload only. TestFlight distribution, App Review and release remain manual.
xcodebuild -quiet -exportArchive \
  -archivePath "$APPLE_CI_DIR/$scheme.xcarchive" \
  -exportPath "$APPLE_CI_DIR/export" \
  -exportOptionsPlist "$APPLE_CI_DIR/ExportOptions.plist" \
  "${authentication[@]}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '### %s %s\n\nUploaded to App Store Connect. Check processing and the final Xcode-managed build number there. No review submission or release was requested.\n' \
    "$BUILD_PLATFORM" "$BUILD_VERSION" >> "$GITHUB_STEP_SUMMARY"
fi
