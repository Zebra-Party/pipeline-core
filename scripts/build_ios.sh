#!/usr/bin/env bash
# Exports a signed iOS .ipa via Godot. Godot 4.6's iOS exporter produces
# a signed IPA directly when application/export_project_only=false.
#
# Env (required):
#   GODOT        — set by install_godot.sh
#   KEYCHAIN_PATH — set by configure_ios_signing.sh
#   GODOT_VERSION — set by install_godot.sh
#
# Env (optional):
#   APP_NAME     — base filename for the IPA, no extension (default: "export")
#   BUILD_DIR    — output directory (default: "build/ios")

set -euo pipefail

: "${GODOT:?GODOT env var not set}"

APP_NAME="${APP_NAME:-export}"
BUILD_DIR="${BUILD_DIR:-build/ios}"
IPA_PATH="$BUILD_DIR/${APP_NAME}.ipa"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Xcode / signing environment:"
echo "  xcode-select: $(xcode-select -p 2>&1 || true)"
xcodebuild -version 2>&1 | sed 's/^/  /' || true
echo
echo "Codesigning identities:"
security find-identity -v -p codesigning "${KEYCHAIN_PATH:-}" 2>&1 | sed 's/^/  /' || true
echo

TEMPLATES_DIR="$HOME/Library/Application Support/Godot/export_templates/${GODOT_VERSION/-stable/.stable}"
if [ ! -f "$TEMPLATES_DIR/ios.zip" ]; then
	echo "::error::Godot iOS export template (ios.zip) is missing from $TEMPLATES_DIR."
	exit 1
fi
echo "✅ ios.zip present ($(stat -f%z "$TEMPLATES_DIR/ios.zip" 2>/dev/null || echo '?') bytes)"
echo

# Serialise the keychain mutation + codesign window with a host-wide lock.
# Two release jobs on the same physical Mac (e.g. multiple self-hosted
# runners under the same user) otherwise race on `security default-keychain
# -s`, and one build's codesign asks the wrong keychain for the signing
# key — returning errSecInternalComponent. shlock uses link(2) for atomic
# acquisition and PID-based stale detection, so a crashed prior build
# doesn't deadlock the next one.
LOCK_FILE="/tmp/godot-ios-codesign.lock"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-1200}"
deadline=$((SECONDS + LOCK_TIMEOUT))
echo "Acquiring iOS codesign lock at $LOCK_FILE..."
until shlock -p $$ -f "$LOCK_FILE" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "::error::Failed to acquire iOS codesign lock within ${LOCK_TIMEOUT}s — is another build hung?"
        exit 1
    fi
    sleep 2
done
trap 'rm -f "$LOCK_FILE"' EXIT
echo "Lock acquired (held for the duration of Godot's iOS export)."

# Re-unlock and re-assert default keychain immediately before Godot runs,
# inside the lock so no other runner can overwrite our default between
# this assertion and the codesign that xcodebuild kicks off internally.
if [ -n "${KEYCHAIN_PATH:-}" ] && [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security default-keychain -s "$KEYCHAIN_PATH"
fi

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
