#!/usr/bin/env bash
# Sets up Apple signing for a native Xcode build (iOS, macOS, or tvOS).
# Imports the distribution cert into a temporary keychain, installs the
# provisioning profile, and writes an ExportOptions.plist for the platform.
#
# Required env vars:
#   APPLE_CERTIFICATE_P12_BASE64  — base64-encoded distribution .p12
#   APPLE_CERTIFICATE_PASSWORD    — password for the .p12
#   APPLE_DISTRIBUTION_PROVISION  — base64-encoded provisioning profile
#                                   (.mobileprovision for iOS/tvOS,
#                                    .provisionprofile for macOS)
#   PLATFORM                      — ios | macos | appletvos
#
# Optional env vars:
#   APPLE_MAC_INSTALLER_P12_BASE64 — base64 Mac Installer Distribution .p12
#                                    (macOS only; needed for signed .pkg)
#   EXPORT_OPTIONS_PATH            — where to write ExportOptions.plist
#                                    (default: build/ExportOptions-<PLATFORM>.plist)
#
# Outputs written to $GITHUB_ENV:
#   KEYCHAIN_PATH
#   KEYCHAIN_PASSWORD
#   TEAM_ID
#   PROVISIONING_PROFILE_UUID_<PLATFORM_UPPER>
#   EXPORT_OPTIONS_PATH_<PLATFORM_UPPER>

set -euo pipefail

: "${APPLE_CERTIFICATE_P12_BASE64:?missing APPLE_CERTIFICATE_P12_BASE64}"
: "${APPLE_CERTIFICATE_PASSWORD:?missing APPLE_CERTIFICATE_PASSWORD}"
: "${APPLE_DISTRIBUTION_PROVISION:?missing APPLE_DISTRIBUTION_PROVISION}"
: "${PLATFORM:?missing PLATFORM — set to ios, macos, or appletvos}"

WORK_DIR="${RUNNER_TEMP:-$(mktemp -d)}"
# Place the keychain inside ~/Library/Keychains/ — securityd restricts
# writes to keychains outside the standard directory on macOS 14+.
mkdir -p "$HOME/Library/Keychains"
KEYCHAIN_PATH="$HOME/Library/Keychains/build-${PLATFORM}.keychain-db"
echo "Runner: $(hostname), user: $(whoami), WORK_DIR=$WORK_DIR, KEYCHAIN=$KEYCHAIN_PATH"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
CERT_PATH="$WORK_DIR/certificate-${PLATFORM}.p12"

if [ "$PLATFORM" = "macos" ]; then
    PROFILE_EXT="provisionprofile"
else
    PROFILE_EXT="mobileprovision"
fi
PROFILE_PATH="$WORK_DIR/profile-${PLATFORM}.${PROFILE_EXT}"

echo "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$CERT_PATH"
echo "$APPLE_DISTRIBUTION_PROVISION"  | base64 --decode > "$PROFILE_PATH"

# Ensure the user's keychain domain is initialised (required on accounts that
# have never had a GUI login; without this, security import fails with
# "Write permissions error / problem decoding").
if ! security list-keychains -d user &>/dev/null; then
    echo "Initialising keychain domain for $(whoami)"
    security create-keychain -p "" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
fi

security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
# Add to search list and set as default BEFORE importing — setting as default
# is required so that xcodebuild's internal codesign subprocess can reach
# the private key without errSecInternalComponent (mirrors configure_ios_signing.sh).
EXISTING=$(security list-keychains -d user 2>/dev/null | tr -d '"' | tr '\n' ' ' || true)
# shellcheck disable=SC2086  # word-split is intentional here
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING 2>/dev/null || true
# Non-fatal: may fail on fresh user accounts without an initialised Library profile.
# Codesign always uses --keychain PATH explicitly so the default is a fallback only.
security default-keychain -s "$KEYCHAIN_PATH" 2>/dev/null || true
security import "$CERT_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" -k "$KEYCHAIN_PATH" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcodebuild
security set-key-partition-list -S "apple-tool:,apple:,codesign:" \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# macOS: optionally import the Mac Installer Distribution cert for signed .pkg.
if [ "$PLATFORM" = "macos" ] && [ -n "${APPLE_MAC_INSTALLER_P12_BASE64:-}" ]; then
    INSTALLER_CERT_PATH="$WORK_DIR/installer_certificate.p12"
    echo "$APPLE_MAC_INSTALLER_P12_BASE64" | base64 --decode > "$INSTALLER_CERT_PATH"
    security import "$INSTALLER_CERT_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" -k "$KEYCHAIN_PATH" -A
    security set-key-partition-list -S "apple-tool:,apple:,codesign:,productbuild:" \
        -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    echo "Mac Installer cert imported"
else
    [ "$PLATFORM" = "macos" ] && echo "No APPLE_MAC_INSTALLER_P12_BASE64 — .pkg will be unsigned"
fi

security find-identity -v -p codesigning "$KEYCHAIN_PATH"

# Decode the provisioning profile and extract identifiers.
PLIST="$(security cms -D -i "$PROFILE_PATH")"
PROFILE_UUID="$(echo "$PLIST" | plutil -extract UUID raw -)"
TEAM_ID="$(echo "$PLIST"  | plutil -extract TeamIdentifier.0 raw -)"
PROFILE_NAME="$(echo "$PLIST" | plutil -extract Name raw -)"

# Extract bundle ID and strip the team prefix.
# iOS/tvOS profiles use 'application-identifier'; macOS profiles use
# 'com.apple.application-identifier' (dotted key — must use PlistBuddy
# because plutil -extract treats dots as path separators).
PLIST_FILE="$WORK_DIR/profile-${PLATFORM}.plist"
echo "$PLIST" > "$PLIST_FILE"
PROFILE_APPID="$(/usr/libexec/PlistBuddy -c 'Print Entitlements:application-identifier' "$PLIST_FILE" 2>/dev/null || true)"
if [ -z "$PROFILE_APPID" ]; then
    PROFILE_APPID="$(/usr/libexec/PlistBuddy -c 'Print Entitlements:com.apple.application-identifier' "$PLIST_FILE" 2>/dev/null || true)"
fi
if [ -n "$PROFILE_APPID" ]; then
    BUNDLE_ID="${PROFILE_APPID#${TEAM_ID}.}"
else
    BUNDLE_ID="*"
fi

# Install the profile so Xcode can find it.
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"
cp "$PROFILE_PATH" "$PROFILE_DIR/${PROFILE_UUID}.${PROFILE_EXT}"

echo "${PLATFORM} signing config:"
echo "  Profile : $PROFILE_NAME ($PROFILE_UUID)"
echo "  Team ID : $TEAM_ID"
echo "  Bundle  : $BUNDLE_ID"

# Write ExportOptions.plist so xcodebuild -exportArchive can consume it.
EXPORT_OPTIONS_PATH="${EXPORT_OPTIONS_PATH:-build/ExportOptions-${PLATFORM}.plist}"
mkdir -p "$(dirname "$EXPORT_OPTIONS_PATH")"

MACOS_EXTRA_KEYS=""
if [ "$PLATFORM" = "macos" ]; then
    # CloudKit requires the container environment to be declared explicitly
    # for app-store-connect exports; omitting it causes an export failure.
    #
    # signingCertificate / installerSigningCertificate tell xcodebuild
    # exactly which cert to use for each role, preventing it from validating
    # the installer cert against the app distribution profile (which causes
    # "Provisioning profile doesn't include signing certificate" errors).
    MACOS_EXTRA_KEYS="    <key>iCloudContainerEnvironment</key>
    <string>Production</string>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
    <key>installerSigningCertificate</key>
    <string>3rd Party Mac Developer Installer</string>"
fi

cat > "$EXPORT_OPTIONS_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>uploadSymbols</key>
    <true/>
${MACOS_EXTRA_KEYS}
    <key>provisioningProfiles</key>
    <dict>
        <key>${BUNDLE_ID}</key>
        <string>${PROFILE_UUID}</string>
    </dict>
</dict>
</plist>
PLIST

echo "Wrote $EXPORT_OPTIONS_PATH"

PLATFORM_UPPER=$(echo "$PLATFORM" | tr '[:lower:]' '[:upper:]')

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "KEYCHAIN_PATH=${KEYCHAIN_PATH}"
        echo "KEYCHAIN_PASSWORD=${KEYCHAIN_PASSWORD}"
        echo "TEAM_ID=${TEAM_ID}"
        echo "PROVISIONING_PROFILE_UUID_${PLATFORM_UPPER}=${PROFILE_UUID}"
        echo "EXPORT_OPTIONS_PATH_${PLATFORM_UPPER}=${EXPORT_OPTIONS_PATH}"
    } >> "$GITHUB_ENV"
fi
