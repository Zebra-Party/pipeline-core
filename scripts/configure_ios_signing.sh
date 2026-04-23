#!/usr/bin/env bash
# Imports the Apple distribution cert into a temporary keychain and
# installs the provisioning profile, then writes the team ID + UUID into
# export_presets.cfg so Godot's iOS exporter knows which identity / profile
# to embed in the generated Xcode project.
#
# Required env vars:
#   APPLE_CERTIFICATE_P12_BASE64        — base64 of distribution .p12
#   APPLE_CERTIFICATE_PASSWORD          — password for the .p12
#   APPLE_IOS_DISTRIBUTION_PROVISION    — base64 of the .mobileprovision
#
# Outputs (set on $GITHUB_ENV when present):
#   IOS_TEAM_ID
#   IOS_PROVISIONING_PROFILE_UUID
#   KEYCHAIN_PATH

set -euo pipefail

: "${APPLE_CERTIFICATE_P12_BASE64:?missing}"
: "${APPLE_CERTIFICATE_PASSWORD:?missing}"
: "${APPLE_IOS_DISTRIBUTION_PROVISION:?missing}"

WORK_DIR="$(mktemp -d)"
KEYCHAIN_PATH="$WORK_DIR/build.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
P12_PATH="$WORK_DIR/cert.p12"
PROFILE_PATH="$WORK_DIR/profile.mobileprovision"

# 1. Materialise the cert + profile from base64.
echo "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$P12_PATH"
echo "$APPLE_IOS_DISTRIBUTION_PROVISION" | base64 --decode > "$PROFILE_PATH"

# 2. Create & unlock a fresh keychain so we don't pollute the runner's login keychain.
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')

security import "$P12_PATH" -k "$KEYCHAIN_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" \
	-T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcodebuild
security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# 3. Install the provisioning profile + extract its identifiers so we
#    can compare them against the bundle id in export_presets.cfg.
PROFILE_PLIST="$(security cms -D -i "$PROFILE_PATH")"
PROFILE_UUID="$(echo "$PROFILE_PLIST" | plutil -extract UUID raw -)"
PROFILE_NAME="$(echo "$PROFILE_PLIST" | plutil -extract Name raw -)"
TEAM_ID="$(echo "$PROFILE_PLIST" | plutil -extract TeamIdentifier.0 raw -)"
PROFILE_APPID="$(echo "$PROFILE_PLIST" | plutil -extract Entitlements.application-identifier raw -)"
# application-identifier is "<TEAMID>.<bundleid>" — strip the team prefix.
PROFILE_BUNDLE_ID="${PROFILE_APPID#${TEAM_ID}.}"
PRESET_BUNDLE_ID="$(grep -E '^application/bundle_identifier=' export_presets.cfg | head -1 | sed -E 's/.*"(.*)"/\1/')"

PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"
cp "$PROFILE_PATH" "$PROFILE_DIR/${PROFILE_UUID}.mobileprovision"

# Always-visible diagnostics — no ::group:: wrapper because GitHub
# collapses groups by default and the iOS export error message is
# unhelpful enough that we want this in the user's face.
echo "iOS signing config:"
echo "  Provisioning profile : $PROFILE_NAME ($PROFILE_UUID)"
echo "  Profile team id      : $TEAM_ID"
echo "  Profile bundle id    : $PROFILE_BUNDLE_ID"
echo "  Preset bundle id     : $PRESET_BUNDLE_ID"
if [ "$PROFILE_BUNDLE_ID" != "$PRESET_BUNDLE_ID" ] && [ "$PROFILE_BUNDLE_ID" != "*" ]; then
	echo "::warning::Provisioning profile is for '$PROFILE_BUNDLE_ID' but the preset's bundle id is '$PRESET_BUNDLE_ID' — Godot will refuse to export."
fi

# 4. Inject team_id + provisioning profile UUID into export_presets.cfg.
#    Mirrors what works in another shipping project: only set these two
#    fields, leave code_sign_identity_release at "iPhone Distribution"
#    (Godot's default), don't touch the debug block at all.
awk \
	-v team="$TEAM_ID" \
	-v uuid="$PROFILE_UUID" \
	'
		/^application\/app_store_team_id=/                       { print "application/app_store_team_id=\"" team "\""; next }
		/^application\/provisioning_profile_specifier_release=/  { print "application/provisioning_profile_specifier_release=\"" uuid "\""; next }
		{ print }
	' export_presets.cfg > export_presets.cfg.tmp
mv export_presets.cfg.tmp export_presets.cfg

# Surface the iOS-relevant fields so failed runs can be diagnosed.
# (Not in a ::group:: — see comment above re collapsed-by-default.)
echo
echo "iOS preset after signing config:"
awk '/^\[preset\.0\]/,/^\[preset\.[1-9]/' export_presets.cfg \
	| grep -vE '^\[preset\.[1-9]' \
	| sed 's/^/  /'
echo

if [ -n "${GITHUB_ENV:-}" ]; then
	{
		echo "IOS_TEAM_ID=$TEAM_ID"
		echo "IOS_PROVISIONING_PROFILE_UUID=$PROFILE_UUID"
		echo "IOS_PROVISIONING_PROFILE_NAME=$PROFILE_NAME"
		echo "KEYCHAIN_PATH=$KEYCHAIN_PATH"
		echo "KEYCHAIN_PASSWORD=$KEYCHAIN_PASSWORD"
	} >> "$GITHUB_ENV"
fi
