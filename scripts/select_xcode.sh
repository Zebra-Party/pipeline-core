#!/usr/bin/env bash
# Picks the newest Xcode.app under /Applications and writes its
# DEVELOPER_DIR to $GITHUB_ENV so subsequent steps invoke the correct
# xcodebuild / codesign / etc.
#
# Self-hosted runners may have multiple Xcode versions installed and
# `xcode-select` may point at the CLI tools rather than an Xcode.app.
# Setting DEVELOPER_DIR per-job picks the newest Xcode without mutating
# the system-wide xcode-select state.

set -euo pipefail

XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)

if [ -z "$XCODE" ] || [ ! -d "$XCODE/Contents/Developer" ]; then
    echo "::error::No Xcode.app found under /Applications/. Install Xcode on this runner." >&2
    exit 1
fi

DEVELOPER_DIR="$XCODE/Contents/Developer"
echo "Selected: $XCODE"
"$DEVELOPER_DIR/usr/bin/xcodebuild" -version 2>&1 | sed 's/^/  /'

if [ -n "${GITHUB_ENV:-}" ]; then
    echo "DEVELOPER_DIR=$DEVELOPER_DIR" >> "$GITHUB_ENV"
fi
