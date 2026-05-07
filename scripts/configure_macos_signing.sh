#!/usr/bin/env bash
# Sets up Apple Distribution signing for macOS builds.
# Imports the distribution cert + optionally the Mac Installer cert,
# installs the provisioning profile, and patches export_presets.cfg.
#
# Required env vars:
#   APPLE_CERTIFICATE_P12_BASE64         — base64 distribution .p12
#   APPLE_CERTIFICATE_PASSWORD           — .p12 password
#   APPLE_MACOS_DISTRIBUTION_PROVISION   — base64 .provisionprofile
#
# Optional env vars:
#   APPLE_MAC_INSTALLER_P12_BASE64       — base64 installer .p12 (for signed .pkg)
#
# Outputs (set on $GITHUB_ENV when present):
#   MACOS_TEAM_ID
#   MACOS_PROVISIONING_PROFILE_UUID
#   KEYCHAIN_PATH
#   KEYCHAIN_PASSWORD

set -euo pipefail

# shellcheck source=keychain_helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/keychain_helpers.sh"

: "${APPLE_CERTIFICATE_P12_BASE64:?missing}"
: "${APPLE_CERTIFICATE_PASSWORD:?missing}"
: "${APPLE_MACOS_DISTRIBUTION_PROVISION:?missing}"

WORK_DIR="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN_PATH="$(keychain_unique_path build-godot-macos)"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
CERT_PATH="$WORK_DIR/certificate.p12"
PROFILE_PATH="$WORK_DIR/profile.provisionprofile"

echo "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$CERT_PATH"
echo "$APPLE_MACOS_DISTRIBUTION_PROVISION" | base64 --decode > "$PROFILE_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
# No -l so the keychain doesn't lock on system sleep mid-build.
security set-keychain-settings -t 21600 -u "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERT_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" -A -f pkcs12 -k "$KEYCHAIN_PATH" \
	-T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcodebuild
security set-key-partition-list -S "apple-tool:,apple:,codesign:" \
	-s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# Godot's macOS export reads identities from the user's search list, and
# `security cms -D` below needs a default keychain to validate the
# profile signature. keychain_assert_active does both under the mutex.
keychain_assert_active "$KEYCHAIN_PATH" "$KEYCHAIN_PASSWORD"

security find-identity -v -p codesigning "$KEYCHAIN_PATH"

# Optional Mac Installer Distribution cert for signed .pkg.
if [ -n "${APPLE_MAC_INSTALLER_P12_BASE64:-}" ]; then
	INSTALLER_CERT_PATH="$WORK_DIR/installer_certificate.p12"
	echo "$APPLE_MAC_INSTALLER_P12_BASE64" | base64 --decode > "$INSTALLER_CERT_PATH"
	security import "$INSTALLER_CERT_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" -A -f pkcs12 -k "$KEYCHAIN_PATH"
	security set-key-partition-list -S "apple-tool:,apple:,codesign:,productbuild:" \
		-s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
	echo "Mac Installer cert imported"
else
	echo "No APPLE_MAC_INSTALLER_P12_BASE64 — .pkg will be unsigned"
fi

# Extract UUID + Team ID from the profile.
PLIST="$(security cms -D -i "$PROFILE_PATH")"
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" /dev/stdin <<< "$PLIST")
TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print TeamIdentifier:0" /dev/stdin <<< "$PLIST")

mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PROFILE_PATH" "$HOME/Library/MobileDevice/Provisioning Profiles/${PROFILE_UUID}.provisionprofile"

echo "macOS signing config:"
echo "  Team ID              : $TEAM_ID"
echo "  Profile UUID         : $PROFILE_UUID"

# Patch export_presets.cfg with team ID + code sign identity.
awk \
	-v team="$TEAM_ID" \
	'
		/^codesign\/apple_team_id=/  { print "codesign/apple_team_id=\"" team "\""; next }
		/^codesign\/identity=/       { print "codesign/identity=\"Apple Distribution\""; next }
		{ print }
	' export_presets.cfg > export_presets.cfg.tmp
mv export_presets.cfg.tmp export_presets.cfg

if [ -n "${GITHUB_ENV:-}" ]; then
	{
		echo "MACOS_TEAM_ID=$TEAM_ID"
		echo "MACOS_PROVISIONING_PROFILE_UUID=$PROFILE_UUID"
		echo "KEYCHAIN_PATH=$KEYCHAIN_PATH"
		echo "KEYCHAIN_PASSWORD=$KEYCHAIN_PASSWORD"
	} >> "$GITHUB_ENV"
fi
