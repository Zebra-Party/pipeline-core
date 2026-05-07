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

# shellcheck source=keychain_helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/keychain_helpers.sh"

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

# Hold the host-wide codesign lock across archive + exportArchive, then
# isolate the user search list to ONLY our keychain (+ login). Sibling
# runners' persistent keychains all contain the same Apple Distribution
# identity (same .p12 secret); without isolation, xcodebuild's identity
# lookup may pick a sibling's keychain and codesign with --keychain
# pointing at OUR kc fails with errSecInternalComponent.
keychain_codesign_lock_acquire
keychain_search_list_isolate "$KEYCHAIN_PATH"

# Defensive: persistent kc is configured with no auto-lock, but a system
# event could still have locked it.
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" 2>/dev/null || true
# Set as user default — some Xcode subroutines (entitlement-DER,
# productbuild) reach for the default keychain even when we pass
# --keychain explicitly. Setting it under the codesign lock means no
# sibling can clobber it before xcodebuild starts.
security default-keychain -s "$KEYCHAIN_PATH"

echo "::group::Keychain state under codesign lock"
echo "default-keychain:"; security default-keychain -d user || true
echo "search list:";      security list-keychains   -d user || true
echo "identities visible to xcodebuild:"
security find-identity -v -p codesigning || true
echo "::endgroup::"

VERSION_ARGS=()
[ -n "${VERSION:-}" ] && VERSION_ARGS+=(MARKETING_VERSION="$VERSION")
[ -n "${BUILD:-}"   ] && VERSION_ARGS+=(CURRENT_PROJECT_VERSION="$BUILD")

SIGNING_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="Apple Distribution"
    DEVELOPMENT_TEAM="$TEAM_ID"
    # Explicit keychain prevents errSecInternalComponent when codesign runs
    # as an xcodebuild subprocess and might otherwise fall back to the
    # search list. -vvvv makes codesign verbose so the next failure carries
    # actionable context inline.
    OTHER_CODE_SIGN_FLAGS="--keychain ${KEYCHAIN_PATH} -vvvv"
)
[ -n "$PROFILE_UUID" ] && SIGNING_ARGS+=(PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID")

ARCHIVE_RC=0
for archive_attempt in 1 2; do
    echo "::group::xcodebuild archive (${PLATFORM}) — attempt ${archive_attempt}/2"
    ARCHIVE_RC=0
    # shellcheck disable=SC2086  # PROJECT_FLAG is intentionally word-split
    xcodebuild archive \
        $PROJECT_FLAG \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        "${SIGNING_ARGS[@]}" \
        "${VERSION_ARGS[@]}" || ARCHIVE_RC=$?
    echo "::endgroup::"
    [ "$ARCHIVE_RC" -eq 0 ] && break
    if [ "$archive_attempt" -lt 2 ]; then
        # codesign --generate-entitlement-der occasionally returns
        # errSecInternalComponent when Apple's cert / chain validation
        # services flake. Sleep + retry once before declaring failure;
        # clear the partial archive so the second attempt doesn't
        # short-circuit to the same broken state.
        echo "::warning::xcodebuild archive failed (rc=$ARCHIVE_RC) — sleeping 15s and retrying once"
        rm -rf "$ARCHIVE_PATH"
        sleep 15
    fi
done

# On both-failures, dump the .xcent (xcodebuild-generated entitlements)
# and the provisioning profile's Entitlements dict so a mismatch is
# visible directly in the log.
if [ "$ARCHIVE_RC" -ne 0 ]; then
    set +e
    echo "::group::Post-failure entitlement diagnostic"
    echo "## .xcent files under DerivedData (most-recently-modified):"
    DD="$HOME/Library/Developer/Xcode/DerivedData"
    if [ -d "$DD" ]; then
        find "$DD" -type f -name "*.xcent" -mtime -1 2>/dev/null \
            | while IFS= read -r xcent; do
                echo
                echo "--- $xcent ---"
                plutil -p "$xcent" 2>/dev/null || cat "$xcent" 2>/dev/null || true
            done
    fi
    echo
    echo "## Provisioning profile Entitlements grants:"
    if [ -n "${PROFILE_UUID:-}" ]; then
        for ext in mobileprovision provisionprofile; do
            pf="$HOME/Library/MobileDevice/Provisioning Profiles/${PROFILE_UUID}.${ext}"
            if [ -f "$pf" ]; then
                echo "--- $pf ---"
                security cms -D -i "$pf" 2>/dev/null \
                    | plutil -extract Entitlements xml1 -o - - 2>/dev/null \
                    | plutil -p - 2>/dev/null \
                    || true
            fi
        done
    else
        echo "(no PROFILE_UUID set; skipping)"
    fi
    echo "::endgroup::"
    set -e
    exit "$ARCHIVE_RC"
fi

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
