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

# shellcheck source=keychain_helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/keychain_helpers.sh"

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

# Defensive re-activate; required because Godot's macOS export shells
# out to codesign without --keychain and falls back to the user's
# search list + default keychain.
if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
    keychain_activate "$KEYCHAIN_PATH" "$KEYCHAIN_PASSWORD"
fi

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

# Embed provisioning profile + re-sign. Pass --keychain explicitly so
# codesign / productbuild don't depend on the search list at signing time.
cp "$PROFILE_PATH" "$APP_PATH/Contents/embedded.provisionprofile"
# Look up the identities by cert presence (no -v) rather than by chain-
# trust validation. On a fresh per-job build keychain right after the
# Apple intermediates are imported, `security find-identity -v` can
# briefly report "0 valid identities found" while the system trust
# evaluator's caches catch up — but codesign with an explicit --keychain
# still uses the cert successfully (Godot's own export step does this
# in the same run). Don't fail the script on a transient cache state
# when the cert is demonstrably present and usable.
IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN_PATH" \
	| grep "Apple Distribution" | head -1 | sed 's/.*"\(.*\)".*/\1/')
[ -n "$IDENTITY" ] || { echo "::error::Apple Distribution identity not in $KEYCHAIN_PATH"; exit 1; }
xattr -cr "$APP_PATH"
# No --keychain here. With --keychain, codesign restricts chain
# assembly to that keychain alone — and our per-job build keychain
# has Apple Root imported only as a regular cert, not as a trust
# anchor, so codesign reports "unable to build chain to self-signed
# root" / errSecInternalComponent. Without --keychain, codesign
# falls back to the user search list (build_kc + login.keychain,
# both pinned by keychain_activate) plus the host's
# SystemRootCertificates.keychain where Apple Root is a real trust
# anchor. The signing identity is found via the search list since
# the build keychain is on it. Godot's own codesign step in the
# preceding export does exactly this.
codesign --force --options runtime --timestamp \
	--sign "$IDENTITY" "$APP_PATH"
echo "Re-signed: $IDENTITY"

# Create .pkg — signed if an installer cert is available, unsigned otherwise.
INSTALLER_IDENTITY=$(security find-identity "$KEYCHAIN_PATH" \
	| grep -E "3rd Party Mac Developer Installer|Mac Installer Distribution" \
	| head -1 | sed 's/.*"\(.*\)".*/\1/' || true)

if [ -n "$INSTALLER_IDENTITY" ]; then
	# See note above codesign re: --keychain — same applies to productbuild's
	# chain assembly for the installer identity.
	productbuild --component "$APP_PATH" /Applications \
		--sign "$INSTALLER_IDENTITY" "$PKG_PATH"
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
