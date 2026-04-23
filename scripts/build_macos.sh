#!/usr/bin/env bash
# Exports a macOS .app via Godot, re-signs it, and creates a .pkg.
#
# Env (required):
#   GODOT                          — set by install_godot.sh
#   KEYCHAIN_PATH                  — set by configure_macos_signing.sh
#   MACOS_PROVISIONING_PROFILE_UUID — set by configure_macos_signing.sh
#
# Env (optional):
#   APP_NAME        — base filename, no extension (default: "export")
#   BUILD_DIR       — output directory (default: "build/macos")
#   MACOS_PRESET    — Godot export preset name (default: "macOS (Universal)")

set -euo pipefail

: "${GODOT:?GODOT env var not set}"
: "${KEYCHAIN_PATH:?KEYCHAIN_PATH not set — call configure_macos_signing.sh first}"
: "${MACOS_PROVISIONING_PROFILE_UUID:?MACOS_PROVISIONING_PROFILE_UUID not set}"

APP_NAME="${APP_NAME:-export}"
BUILD_DIR="${BUILD_DIR:-build/macos}"
MACOS_PRESET="${MACOS_PRESET:-macOS (Universal)}"
APP_PATH="$BUILD_DIR/${APP_NAME}.app"
PKG_PATH="$BUILD_DIR/${APP_NAME}.pkg"
PROFILE_PATH="$HOME/Library/MobileDevice/Provisioning Profiles/${MACOS_PROVISIONING_PROFILE_UUID}.provisionprofile"

mkdir -p "$BUILD_DIR"

echo "::group::Godot --export-release"
"$GODOT" --headless --path . --export-release "$MACOS_PRESET" "$APP_PATH"
echo "::endgroup::"

# Godot may produce a .zip containing the .app rather than a bare .app.
# Unwrap it if needed.
if [ ! -d "$APP_PATH" ] && [ -f "$BUILD_DIR/${APP_NAME}.zip" ]; then
	unzip -q "$BUILD_DIR/${APP_NAME}.zip" -d "$BUILD_DIR"
	APP_PATH="$(find "$BUILD_DIR" -name "*.app" -type d -maxdepth 2 -print -quit)"
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
	echo "::error::No .app produced in $BUILD_DIR"
	ls -la "$BUILD_DIR" || true
	exit 1
fi
echo "Built .app: $APP_PATH"

# Embed provisioning profile + re-sign.
cp "$PROFILE_PATH" "$APP_PATH/Contents/embedded.provisionprofile"
IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
	| grep "Apple Distribution" | head -1 | sed 's/.*"\(.*\)".*/\1/')
xattr -cr "$APP_PATH"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_PATH"
echo "Re-signed: $IDENTITY"

# Create .pkg — signed if an installer cert is available, unsigned otherwise.
INSTALLER_IDENTITY=$(security find-identity -v "$KEYCHAIN_PATH" \
	| grep -E "3rd Party Mac Developer Installer|Mac Installer Distribution" \
	| head -1 | sed 's/.*"\(.*\)".*/\1/' || true)

if [ -n "$INSTALLER_IDENTITY" ]; then
	productbuild --component "$APP_PATH" /Applications --sign "$INSTALLER_IDENTITY" "$PKG_PATH"
	echo "Signed .pkg: $PKG_PATH"
else
	echo "::warning::No installer cert — producing unsigned .pkg (TestFlight upload will fail without it)"
	productbuild --component "$APP_PATH" /Applications "$PKG_PATH"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
	{
		echo "APP_PATH=$APP_PATH"
		echo "PKG_PATH=$PKG_PATH"
	} >> "$GITHUB_ENV"
fi
