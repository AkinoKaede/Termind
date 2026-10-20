#!/bin/sh
set -eu

source_plist="${SRCROOT}/Configuration/Firebase/GoogleService-Info.plist"
bundled_plist="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/GoogleService-Info.plist"

if [ ! -f "${source_plist}" ]; then
    # An incremental build must not retain another developer's service configuration.
    rm -f "${bundled_plist}"
    exit 0
fi

mkdir -p "$(dirname "${bundled_plist}")"
cp "${source_plist}" "${bundled_plist}"

if [ "${CONFIGURATION}" = "Release" ] && [ "${FIREBASE_UPLOAD_SYMBOLS:-NO}" = "YES" ]; then
    "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run" -gsp "${bundled_plist}"
fi
