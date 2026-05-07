#!/usr/bin/env bash
# Picks the Xcode.app to use and writes its DEVELOPER_DIR to $GITHUB_ENV
# so subsequent steps invoke the correct xcodebuild / codesign / etc.
#
# Order of preference:
#   1. $XCODE_OVERRIDE env var if it points at a valid Xcode.app
#      (per-job override; useful in CI when one workflow needs to pin
#      a specific Xcode without disturbing others).
#   2. The system-wide `xcode-select -p` choice — operators can pin a
#      known-good Xcode via `sudo xcode-select -s /Applications/XcodeNN.app`
#      and it'll be honoured here. We only honour it when it points
#      inside /Applications/Xcode*.app (not /Library/Developer/CommandLineTools,
#      which can't drive xcodebuild).
#   3. The newest Xcode under /Applications/, by version sort. Fallback for
#      runners that haven't been pinned (or GitHub-hosted runners).

set -euo pipefail

select_xcode() {
    if [ -n "${XCODE_OVERRIDE:-}" ]; then
        if [ -d "${XCODE_OVERRIDE%/}/Contents/Developer" ]; then
            echo "${XCODE_OVERRIDE%/}"; return 0
        fi
        echo "::warning::XCODE_OVERRIDE=$XCODE_OVERRIDE doesn't exist; falling through" >&2
    fi
    local pinned
    pinned=$(/usr/bin/xcode-select -p 2>/dev/null || true)
    if [[ "$pinned" == /Applications/Xcode*.app/Contents/Developer ]]; then
        echo "${pinned%/Contents/Developer}"; return 0
    fi
    ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1
}

XCODE=$(select_xcode)

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
