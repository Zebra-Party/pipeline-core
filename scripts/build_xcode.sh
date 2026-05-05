#!/usr/bin/env bash
# Archives and exports a native Xcode project for a given Apple platform.
# Prefers an .xcworkspace over an .xcodeproj at the repo root (CocoaPods etc).
#
# Required env vars:
#   PLATFORM          — ios | macos | appletvos
#   APP_NAME          — Xcode scheme name and output file basename
#   KEYCHAIN_PATH     — set by configure_xcode_signing.sh
#   KEYCHAIN_PASSWORD — set by configure_xcode_signing.sh
#   TEAM_ID           — set by configure_xcode_signing.sh
#
# The provisioning profile UUID and ExportOptions path are read from
# env vars set by configure_xcode_signing.sh:
#   PROVISIONING_PROFILE_UUID_<PLATFORM_UPPER>
#   EXPORT_OPTIONS_PATH_<PLATFORM_UPPER>   (falls back to build/ExportOptions-<PLATFORM>.plist)
#
# Optional env vars:
#   SCHEME        — Xcode scheme (defaults to APP_NAME)
#   BUILD_DIR     — output directory (default: build/<PLATFORM>)
#   VERSION       — MARKETING_VERSION override (e.g. from compute_version.sh)
#   BUILD         — CURRENT_PROJECT_VERSION override
#
# Outputs written to $GITHUB_ENV:
#   IPA_PATH   (ios / appletvos)
#   PKG_PATH   (macos)

set -euo pipefail

: "${PLATFORM:?missing PLATFORM — set to ios, macos, or appletvos}"
: "${APP_NAME:?missing APP_NAME}"
: "${KEYCHAIN_PATH:?missing KEYCHAIN_PATH — call configure_xcode_signing.sh first}"
: "${KEYCHAIN_PASSWORD:?missing KEYCHAIN_PASSWORD}"
: "${TEAM_ID:?missing TEAM_ID}"

SCHEME="${SCHEME:-${APP_NAME}}"
BUILD_DIR="${BUILD_DIR:-build/${PLATFORM}}"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"

PLATFORM_UPPER=$(echo "$PLATFORM" | tr '[:lower:]' '[:upper:]')

PROFILE_UUID_VAR="PROVISIONING_PROFILE_UUID_${PLATFORM_UPPER}"
PROFILE_UUID="${!PROFILE_UUID_VAR:-}"

EXPORT_OPTIONS_VAR="EXPORT_OPTIONS_PATH_${PLATFORM_UPPER}"
EXPORT_OPTIONS_PATH="${!EXPORT_OPTIONS_VAR:-build/ExportOptions-${PLATFORM}.plist}"

case "$PLATFORM" in
    ios)       DESTINATION="generic/platform=iOS" ;;
    macos)     DESTINATION="generic/platform=macOS" ;;
    appletvos) DESTINATION="generic/platform=tvOS" ;;
    *)         echo "::error::Unknown PLATFORM '$PLATFORM'"; exit 1 ;;
esac

mkdir -p "$BUILD_DIR"

# Detect whether to use a workspace or project.
if [ -f "${APP_NAME}.xcworkspace/contents.xcworkspacedata" ]; then
    PROJECT_FLAG="-workspace ${APP_NAME}.xcworkspace"
elif [ -d "${APP_NAME}.xcodeproj" ]; then
    PROJECT_FLAG="-project ${APP_NAME}.xcodeproj"
else
    echo "::error::No ${APP_NAME}.xcworkspace or ${APP_NAME}.xcodeproj found"
    exit 1
fi

# Re-unlock keychain immediately before xcodebuild — it may lock between steps.
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security default-keychain -s "$KEYCHAIN_PATH"

VERSION_ARGS=()
[ -n "${VERSION:-}" ] && VERSION_ARGS+=(MARKETING_VERSION="$VERSION")
[ -n "${BUILD:-}"   ] && VERSION_ARGS+=(CURRENT_PROJECT_VERSION="$BUILD")

SIGNING_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="Apple Distribution"
    DEVELOPMENT_TEAM="$TEAM_ID"
)
[ -n "$PROFILE_UUID" ] && SIGNING_ARGS+=(PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID")

echo "::group::xcodebuild archive (${PLATFORM})"
# shellcheck disable=SC2086  # PROJECT_FLAG is intentionally word-split
xcodebuild archive \
    $PROJECT_FLAG \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    "${SIGNING_ARGS[@]}" \
    "${VERSION_ARGS[@]}"
echo "::endgroup::"

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "::error::Archive not produced at $ARCHIVE_PATH"
    exit 1
fi
echo "Archive: $ARCHIVE_PATH"

echo "::group::xcodebuild -exportArchive (${PLATFORM})"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH" \
    -allowProvisioningUpdates
echo "::endgroup::"

if [ "$PLATFORM" = "macos" ]; then
    PKG_PATH="$(find "$EXPORT_DIR" -name "*.pkg" -maxdepth 2 -print -quit || true)"
    if [ -z "$PKG_PATH" ]; then
        echo "::error::No .pkg found in $EXPORT_DIR"
        ls -la "$EXPORT_DIR" || true
        exit 1
    fi
    echo "Built pkg: $PKG_PATH"
    [ -n "${GITHUB_ENV:-}" ] && echo "PKG_PATH=$PKG_PATH" >> "$GITHUB_ENV"
else
    IPA_PATH="$(find "$EXPORT_DIR" -name "*.ipa" -maxdepth 2 -print -quit || true)"
    if [ -z "$IPA_PATH" ]; then
        echo "::error::No .ipa found in $EXPORT_DIR"
        ls -la "$EXPORT_DIR" || true
        exit 1
    fi
    echo "Built IPA: $IPA_PATH"
    [ -n "${GITHUB_ENV:-}" ] && echo "IPA_PATH=$IPA_PATH" >> "$GITHUB_ENV"
fi
