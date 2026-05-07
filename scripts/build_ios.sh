#!/usr/bin/env bash
# Exports a signed iOS .ipa via Godot. Godot 4.6's iOS exporter produces
# a signed IPA directly when application/export_project_only=false.
#
# Env (required):
#   GODOT          — set by install_godot.sh
#   KEYCHAIN_PATH  — set by configure_ios_signing.sh
#   GODOT_VERSION  — set by install_godot.sh
#
# Env (optional):
#   APP_NAME       — base filename for the IPA, no extension (default: "export")
#   BUILD_DIR      — output directory (default: "build/ios")
#   KEYCHAIN_PASSWORD — set by configure_ios_signing.sh; used for defensive unlock

set -euo pipefail

# shellcheck source=keychain_helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/keychain_helpers.sh"

: "${GODOT:?GODOT env var not set}"

APP_NAME="${APP_NAME:-export}"
BUILD_DIR="${BUILD_DIR:-build/ios}"
IPA_PATH="$BUILD_DIR/${APP_NAME}.ipa"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Xcode / signing environment:"
echo "  xcode-select: $(xcode-select -p 2>&1 || true)"
xcodebuild -version 2>&1 | sed 's/^/  /' || true

TEMPLATES_DIR="$HOME/Library/Application Support/Godot/export_templates/${GODOT_VERSION/-stable/.stable}"
if [ ! -f "$TEMPLATES_DIR/ios.zip" ]; then
	echo "::error::Godot iOS export template (ios.zip) is missing from $TEMPLATES_DIR."
	exit 1
fi
echo "✅ ios.zip present ($(stat -f%z "$TEMPLATES_DIR/ios.zip" 2>/dev/null || echo '?') bytes)"

# Hold the host-wide codesign lock + isolate the search list so Godot's
# internal codesign (which runs without --keychain) finds only this
# runner's identity. Sibling runners' persistent keychains all hold the
# same Apple Distribution cert; without isolation, identity lookup is
# non-deterministic.
keychain_codesign_lock_acquire
[ -n "${KEYCHAIN_PATH:-}" ] && keychain_search_list_isolate "$KEYCHAIN_PATH"

# Defensive unlock + pin as default keychain. Godot's exporter calls
# codesign without --keychain, so it relies on the user's search list +
# default keychain. Both are now constrained to our keychain.
if [ -n "${KEYCHAIN_PATH:-}" ] && [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" 2>/dev/null || true
    security default-keychain -s "$KEYCHAIN_PATH"
fi

echo "::group::Keychain state under codesign lock"
security default-keychain -d user || true
security list-keychains   -d user || true
security find-identity -v -p codesigning "${KEYCHAIN_PATH:-}" || true
echo "::endgroup::"

echo "::group::Godot --export-release"
"$GODOT" --headless --path . --export-release "iOS" "$IPA_PATH"
echo "::endgroup::"

if [ ! -f "$IPA_PATH" ]; then
	echo "❌ No .ipa produced at $IPA_PATH"
	ls -la "$BUILD_DIR" || true
	exit 1
fi

echo "Built IPA: $IPA_PATH ($(stat -f%z "$IPA_PATH") bytes)"

echo "::group::Verify IPA"
WORK="$(mktemp -d)"
python3 -m zipfile -e "$IPA_PATH" "$WORK/"
APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' -print -quit)"
if [ -z "$APP" ]; then
	echo "❌ no .app inside Payload/"
	exit 1
fi
PCK="$(find "$APP" -maxdepth 2 -name '*.pck' -print -quit)"
if [ -z "$PCK" ] || [ ! -s "$PCK" ]; then
	echo "❌ no non-empty .pck inside $APP"
	exit 1
fi
echo "  Found $(basename "$PCK") — $(stat -f%z "$PCK") bytes"
codesign --verify --deep --strict "$APP" || { echo "❌ invalid signature"; exit 1; }
echo "  Signature verified"
rm -rf "$WORK"
echo "::endgroup::"

if [ -n "${GITHUB_ENV:-}" ]; then
	echo "IPA_PATH=$IPA_PATH" >> "$GITHUB_ENV"
fi
