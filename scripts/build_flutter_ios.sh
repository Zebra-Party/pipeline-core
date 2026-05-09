#!/usr/bin/env bash
# Flutter-aware iOS build + export. Compiles the Dart code with
# `flutter build ios --no-codesign`, then runs `xcodebuild archive` and
# `xcodebuild -exportArchive` against `ios/Runner.xcworkspace` using the
# manual signing settings prepared by configure_xcode_signing.sh.
#
# We deliberately do NOT use `flutter build ipa` — it doesn't expose a way
# to pass manual signing settings to the underlying archive step, so any
# misconfiguration results in Xcode silently retrying with automatic
# signing and a useless error. Going through xcodebuild directly mirrors
# build_xcode.sh and keeps the signing path identical to the native iOS
# release path.
#
# Required env vars (set by configure_xcode_signing.sh with PLATFORM=ios):
#   KEYCHAIN_PATH, KEYCHAIN_PASSWORD, TEAM_ID
#   PROVISIONING_PROFILE_UUID_IOS
#   EXPORT_OPTIONS_PATH_IOS
#
# Optional env vars:
#   APP_NAME   — used for the IPA filename + xcarchive name (default: Runner)
#   VERSION    — passed to --build-name and MARKETING_VERSION
#   BUILD      — passed to --build-number and CURRENT_PROJECT_VERSION
#   BUNDLE_ID  — overrides PRODUCT_BUNDLE_IDENTIFIER. Use when the desired
#                bundle ID isn't `<org>.<lowerCamelCase(project_name)>`.
#                Must match the bundle ID embedded in the provisioning
#                profile, otherwise the export step fails.
#   BUILD_DIR  — output directory (default: build/flutter-ios)
#   SCHEME     — Xcode scheme (default: Runner)
#
# Outputs written to $GITHUB_ENV:
#   IPA_PATH

set -euo pipefail

# shellcheck source=keychain_helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/keychain_helpers.sh"

: "${KEYCHAIN_PATH:?missing KEYCHAIN_PATH — call configure_xcode_signing.sh first}"
: "${KEYCHAIN_PASSWORD:?missing KEYCHAIN_PASSWORD}"
: "${TEAM_ID:?missing TEAM_ID}"
: "${EXPORT_OPTIONS_PATH_IOS:?missing EXPORT_OPTIONS_PATH_IOS}"

APP_NAME="${APP_NAME:-Runner}"
SCHEME="${SCHEME:-Runner}"
WORKSPACE="ios/Runner.xcworkspace"
BUILD_DIR="${BUILD_DIR:-build/flutter-ios}"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
PROFILE_UUID="${PROVISIONING_PROFILE_UUID_IOS:-}"

if [ ! -d "$WORKSPACE" ]; then
    echo "::error::No $WORKSPACE — run 'flutter create --platforms=ios .' first"
    exit 1
fi

# Disable code signing on every Pod target. Without this, embedded
# plugin frameworks (Flutter.framework, sqlite3.framework, …) get
# signed independently during their own build — the export step then
# refuses with "X.framework does not support provisioning profiles"
# because their auto-generated bundle IDs aren't in the manual
# ExportOptions.plist (and frameworks can't take profiles anyway).
# Turning off signing here lets the Runner target's "Embed Frameworks"
# build phase sign them in place using Runner's Apple Distribution cert.
#
# CocoaPods 1.16 rejects a Podfile that declares more than one
# `post_install` block, so we splice the signing-disable lines into
# the existing block (the one `flutter create` writes calling
# `flutter_additional_ios_build_settings`) rather than appending a new
# one. Ruby ships with macOS and is what CocoaPods uses — saves us a
# brittle multi-line sed.
PODFILE="ios/Podfile"
if [ -f "$PODFILE" ] && ! grep -q "CODE_SIGNING_ALLOWED.*=.*'NO'" "$PODFILE"; then
    ruby <<'RUBY'
path = 'ios/Podfile'
content = File.read(path)
inject = <<~INJECT
      target.build_configurations.each do |config|
        config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
        config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
        config.build_settings['EXPANDED_CODE_SIGN_IDENTITY'] = ''
      end
INJECT
needle = 'flutter_additional_ios_build_settings(target)'
unless content.include?(needle)
  warn "::warning::Podfile doesn't contain '#{needle}', signing-disable injection skipped"
  exit 0
end
content.sub!(needle, needle + "\n" + inject.chomp)
File.write(path, content)
puts "Patched #{path} to disable code signing on Pod targets"
RUBY
fi

# `flutter build ios --no-codesign` runs `pod install`, compiles the Dart
# AOT snapshot, and assembles Runner.app under build/ios/iphoneos/. The
# subsequent xcodebuild archive picks that up.
echo "::group::flutter build ios (no-codesign)"
FLUTTER_ARGS=(--release --no-codesign)
[ -n "${VERSION:-}" ] && FLUTTER_ARGS+=(--build-name "$VERSION")
[ -n "${BUILD:-}"   ] && FLUTTER_ARGS+=(--build-number "$BUILD")
flutter build ios "${FLUTTER_ARGS[@]}"
echo "::endgroup::"

# Defensive re-unlock + re-assert default + search list. Same reasoning
# as build_xcode.sh — Xcode's archive step shells out to codesign helpers
# that bypass --keychain and fall back to the user's default keychain.
keychain_activate "$KEYCHAIN_PATH" "$KEYCHAIN_PASSWORD"
security set-key-partition-list -S "apple-tool:,apple:,codesign:" \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"

mkdir -p "$BUILD_DIR"

# Pin PROVISIONING_PROFILE_SPECIFIER via the Runner target's Release
# xcconfig rather than xcodebuild CLI. xcodebuild CLI build settings
# propagate to every target in the build graph — including the Pods
# project, which contains targets like `sqlite3`, `Pods-Runner` etc.
# Those targets don't support provisioning profiles and abort the
# archive with "X does not support provisioning profiles, but
# provisioning profile <UUID> has been manually specified". Pods don't
# include Flutter/Release.xcconfig, so writing the setting there scopes
# it to Runner only.
RELEASE_XCCONFIG="ios/Flutter/Release.xcconfig"
if [ -n "$PROFILE_UUID" ] && [ -f "$RELEASE_XCCONFIG" ]; then
    {
        echo ""
        echo "// Injected by build_flutter_ios.sh"
        echo "PROVISIONING_PROFILE_SPECIFIER = $PROFILE_UUID"
    } >> "$RELEASE_XCCONFIG"
    echo "Wrote PROVISIONING_PROFILE_SPECIFIER to $RELEASE_XCCONFIG"
fi

SIGNING_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="Apple Distribution"
    DEVELOPMENT_TEAM="$TEAM_ID"
    OTHER_CODE_SIGN_FLAGS="--keychain ${KEYCHAIN_PATH}"
)

VERSION_ARGS=()
[ -n "${VERSION:-}" ] && VERSION_ARGS+=(MARKETING_VERSION="$VERSION")
[ -n "${BUILD:-}"   ] && VERSION_ARGS+=(CURRENT_PROJECT_VERSION="$BUILD")

BUNDLE_ID_ARGS=()
if [ -n "${BUNDLE_ID:-}" ]; then
    BUNDLE_ID_ARGS+=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")
    echo "Overriding PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"
fi

echo "::group::xcodebuild archive (${SCHEME})"
xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -destination "generic/platform=iOS" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    "${SIGNING_ARGS[@]}" \
    "${VERSION_ARGS[@]}" \
    "${BUNDLE_ID_ARGS[@]}"
echo "::endgroup::"

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "::error::Archive not produced at $ARCHIVE_PATH"
    exit 1
fi

echo "::group::xcodebuild -exportArchive (${SCHEME})"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH_IOS" \
    -allowProvisioningUpdates
echo "::endgroup::"

IPA_PATH="$(find "$EXPORT_DIR" -maxdepth 2 -name '*.ipa' -print -quit || true)"
if [ -z "$IPA_PATH" ]; then
    echo "::error::No .ipa found in $EXPORT_DIR"
    ls -la "$EXPORT_DIR" || true
    exit 1
fi

# Rename Runner.ipa to <APP_NAME>.ipa so the artefact is identifiable
# when multiple Flutter apps share the same runner cache directory.
if [ "$APP_NAME" != "Runner" ]; then
    NEW_PATH="$EXPORT_DIR/${APP_NAME}.ipa"
    mv "$IPA_PATH" "$NEW_PATH"
    IPA_PATH="$NEW_PATH"
fi

echo "Built IPA: $IPA_PATH"
[ -n "${GITHUB_ENV:-}" ] && echo "IPA_PATH=$IPA_PATH" >> "$GITHUB_ENV"
