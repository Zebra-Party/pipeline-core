#!/usr/bin/env bash
# Uploads the built .pkg to App Store Connect via xcrun altool.

set -euo pipefail

: "${PKG_PATH:?PKG_PATH env var not set — call build_macos.sh first}"
: "${APP_STORE_CONNECT_ISSUER_ID:?missing}"
: "${APP_STORE_CONNECT_KEY_ID:?missing}"
: "${APP_STORE_CONNECT_PRIVATE_KEY_BASE64:?missing}"

KEY_DIR="$HOME/.appstoreconnect/private_keys"
KEY_PATH="$KEY_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"

mkdir -p "$KEY_DIR"
echo "$APP_STORE_CONNECT_PRIVATE_KEY_BASE64" | base64 --decode > "$KEY_PATH"
chmod 600 "$KEY_PATH"

echo "::group::altool upload (macOS)"
xcrun altool --upload-app \
	--type macos \
	--file "$PKG_PATH" \
	--apiKey "$APP_STORE_CONNECT_KEY_ID" \
	--apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
echo "::endgroup::"

rm -f "$KEY_PATH"
