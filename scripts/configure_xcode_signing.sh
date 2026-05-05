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
KEYCHAIN_PATH="$WORK_DIR/build-${PLATFORM}.keychain-db"
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

security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERT_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" -f pkcs12 -k "$KEYCHAIN_PATH" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcodebuild
security set-key-partition-list -S "apple-tool:,apple:,codesign:" \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

EXISTING=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING
security default-keychain -s "$KEYCHAIN_PATH"

# macOS: optionally import the Mac Installer Distribution cert for signed .pkg.
if [ "$PLATFORM" = "macos" ] && [ -n "${APPLE_MAC_INSTALLER_P12_BASE64:-}" ]; then
    INSTALLER_CERT_PATH="$WORK_DIR/installer_certificate.p12"
    echo "$APPLE_MAC_INSTALLER_P12_BASE64" | base64 --decode > "$INSTALLER_CERT_PATH"
    security import "$INSTALLER_CERT_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" -A -f pkcs12 -k "$KEYCHAIN_PATH"
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

# Extract bundle ID from Entitlements.application-identifier (strip team prefix).
# Falls back to "*" if the key is absent (wildcard profile).
PROFILE_APPID="$(echo "$PLIST" | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)"
if [ -z "$PROFILE_APPID" ]; then
    PROFILE_APPID="$(echo "$PLIST" | plutil -extract Entitlements.com.apple.application-identifier raw - 2>/dev/null || true)"
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
