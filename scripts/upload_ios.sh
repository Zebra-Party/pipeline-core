#!/usr/bin/env bash
# Uploads the built .ipa to App Store Connect via xcrun altool. The user
# decides downstream whether to release or only let it sit on TestFlight;
# we only do the upload here.

set -euo pipefail

: "${IPA_PATH:?IPA_PATH env var not set — call build_ios.sh first}"
: "${APP_STORE_CONNECT_ISSUER_ID:?missing}"
: "${APP_STORE_CONNECT_KEY_ID:?missing}"
: "${APP_STORE_CONNECT_PRIVATE_KEY_BASE64:?missing}"

KEY_DIR="$HOME/.appstoreconnect/private_keys"
KEY_PATH="$KEY_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"

mkdir -p "$KEY_DIR"
echo "$APP_STORE_CONNECT_PRIVATE_KEY_BASE64" | base64 --decode > "$KEY_PATH"
chmod 600 "$KEY_PATH"

echo "::group::altool upload"
xcrun altool --upload-app \
	--type ios \
	--file "$IPA_PATH" \
	--apiKey "$APP_STORE_CONNECT_KEY_ID" \
	--apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
echo "::endgroup::"

# Don't leave the key on disk for the next run.
rm -f "$KEY_PATH"
