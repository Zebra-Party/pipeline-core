#!/usr/bin/env bash
# Uploads a tvOS .ipa to App Store Connect via xcrun altool.

set -euo pipefail

: "${IPA_PATH:?IPA_PATH not set — call build_xcode.sh first}"
: "${APP_STORE_CONNECT_ISSUER_ID:?missing APP_STORE_CONNECT_ISSUER_ID}"
: "${APP_STORE_CONNECT_KEY_ID:?missing APP_STORE_CONNECT_KEY_ID}"
: "${APP_STORE_CONNECT_PRIVATE_KEY_BASE64:?missing APP_STORE_CONNECT_PRIVATE_KEY_BASE64}"

KEY_DIR="$HOME/.appstoreconnect/private_keys"
KEY_PATH="$KEY_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"

mkdir -p "$KEY_DIR"
echo "$APP_STORE_CONNECT_PRIVATE_KEY_BASE64" | base64 --decode > "$KEY_PATH"
chmod 600 "$KEY_PATH"

echo "::group::altool upload (tvOS)"
xcrun altool --upload-app \
    --type appletvos \
    --file "$IPA_PATH" \
    --apiKey "$APP_STORE_CONNECT_KEY_ID" \
    --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
echo "::endgroup::"

rm -f "$KEY_PATH"
