#!/usr/bin/env bash
# Sets up Apple Distribution + Mac Installer signing for Godot macOS builds.
# Ensures the per-runner persistent keychain has the current cert(s) (lazy
# build via setup_runner_keychain), installs the provisioning profile, and
# patches export_presets.cfg.
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
PROFILE_PATH="$WORK_DIR/profile.provisionprofile"
echo "$APPLE_MACOS_DISTRIBUTION_PROVISION" | base64 --decode > "$PROFILE_PATH"

# Build / refresh the runner's persistent keychain. setup_runner_keychain
# picks up APPLE_MAC_INSTALLER_P12_BASE64 when set and adds the installer
# cert to the same kc. Idempotent — no-op fast path when the cert hasn't
# rotated.
KEYCHAIN_PATH="$(setup_runner_keychain)"
KEYCHAIN_PASSWORD="$APPLE_CERTIFICATE_PASSWORD"

if [ -z "${APPLE_MAC_INSTALLER_P12_BASE64:-}" ]; then
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
echo "  Keychain             : $KEYCHAIN_PATH"

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
