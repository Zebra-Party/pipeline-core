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

# Re-unlock + re-assert partition ACLs + (under the cross-runner mutex)
# default-keychain and search-list. xcodebuild's archive step has Xcode
# code paths that ignore OTHER_CODE_SIGN_FLAGS=--keychain (notably the
# entitlement-DER step) and fall back to the user's default keychain —
# without this assertion they trip errSecInternalComponent on multi-
# runner setups where another job has just set the default to its own
# (now-deleted) build keychain.
keychain_assert_active "$KEYCHAIN_PATH" "$KEYCHAIN_PASSWORD"
PARTITION_LIST="apple-tool:,apple:,codesign:"
[ "$PLATFORM" = "macos" ] && PARTITION_LIST="${PARTITION_LIST},productbuild:"
security set-key-partition-list -S "$PARTITION_LIST" \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"

# Hold the host-wide codesign lock across archive + exportArchive.
# xcodebuild has Xcode subroutines (entitlement DER, productbuild) that
# ignore OTHER_CODE_SIGN_FLAGS=--keychain and reach for the user's
# default keychain — which is shared across all runners on this user.
# Without this serialisation a sibling job's keychain_assert_active
# clobbers our default mid-archive and we trip errSecInternalComponent.
keychain_codesign_lock_acquire

# Isolate the search list to ONLY our build keychain (+ login). Sibling
# per-job keychains contain the same Apple Distribution cert (same .p12),
# and xcodebuild's identity lookup walks the search list — without isolation
# it may pick a sibling's identity, then codesign with --keychain pointing
# at OUR kc fails with errSecInternalComponent because the matching private
# key is in the sibling's keychain.
keychain_search_list_isolate "$KEYCHAIN_PATH"

# Diagnostics + defensive re-establish: 30+ seconds may have elapsed
# while we waited for the lock; sibling runners' cleanup steps may have
# rewritten the default keychain in that window. Re-unlock and re-assert
# before xcodebuild, then dump state so any future failure has the
# keychain context inline.
echo "::group::Keychain state under codesign lock"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
keychain_assert_active "$KEYCHAIN_PATH" "$KEYCHAIN_PASSWORD"
echo "default-keychain:"; security default-keychain -d user || true
echo "search list:";      security list-keychains   -d user || true
echo "identities visible to xcodebuild (search list):"
security find-identity -v -p codesigning || true
echo "identities in our keychain:"
security find-identity -v -p codesigning "$KEYCHAIN_PATH" || true
echo "::endgroup::"

echo "::group::Smoke-test codesign (retried until securityd settles)"
# Concurrent sibling jobs running configure_xcode_signing.sh do
# `security set-key-partition-list` on their own keychains. While that's
# in flight, our codesign on our own keychain transiently returns
# errSecInternalComponent — even though the keychain ends up fine.
# Retry the smoke test a few times before declaring it broken; a
# successful smoke is a reliable predictor of real-build success.
SMOKE_OK=0
for attempt in 1 2 3 4 5 6; do
    if keychain_smoke_test_codesign "$KEYCHAIN_PATH"; then
        SMOKE_OK=1
        break
    fi
    if [ "$attempt" -lt 6 ]; then
        echo "Smoke test failed (attempt $attempt/6) — sleeping 3s for sibling configures to settle..."
        sleep 3
    fi
done
if [ "$SMOKE_OK" -ne 1 ]; then
    echo "::error::Smoke test still failing after 6 attempts — keychain access truly broken; aborting before xcodebuild burns time"
    exit 1
fi
echo "::endgroup::"

VERSION_ARGS=()
[ -n "${VERSION:-}" ] && VERSION_ARGS+=(MARKETING_VERSION="$VERSION")
[ -n "${BUILD:-}"   ] && VERSION_ARGS+=(CURRENT_PROJECT_VERSION="$BUILD")

SIGNING_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="Apple Distribution"
    DEVELOPMENT_TEAM="$TEAM_ID"
    # Explicit keychain path prevents errSecInternalComponent when codesign
    # runs as an xcodebuild subprocess and the default keychain has shifted.
    # -vvvv (verbose×4) makes codesign print its internal diagnostic on
    # failure — without it we get only the bare "errSecInternalComponent"
    # which is generic and unactionable.
    OTHER_CODE_SIGN_FLAGS="--keychain ${KEYCHAIN_PATH} -vvvv"
)
[ -n "$PROFILE_UUID" ] && SIGNING_ARGS+=(PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID")

echo "::group::xcodebuild archive (${PLATFORM})"
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

# On failure, dump the .xcent (xcodebuild-generated entitlements) and the
# provisioning profile's Entitlements dict so a mismatch between the two
# (which is the typical cause of errSecInternalComponent at
# `codesign --generate-entitlement-der`) is visible directly in the log.
if [ "$ARCHIVE_RC" -ne 0 ]; then
    set +e
    echo "::group::Post-failure entitlement diagnostic"
    echo "## .xcent files under DerivedData (most-recently-modified last):"
    DD="$HOME/Library/Developer/Xcode/DerivedData"
    if [ -d "$DD" ]; then
        # Sorted by mtime; last entries are from this build. Limit to recent
        # ones so we don't dump every historical .xcent on the runner.
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
