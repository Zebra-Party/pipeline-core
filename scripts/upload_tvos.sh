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

ALTOOL_LOG=$(mktemp /tmp/altool-output.XXXXXX)
trap 'rm -f "$ALTOOL_LOG" "$KEY_PATH"' EXIT

# altool uploads can fail on transient conditions that a clean re-run clears:
#   * "The network connection was lost (-1005)" — runner ↔ Apple blip mid-transfer.
#   * "Unable to authenticate (-19209) / 401" during asset-state polling — the
#     per-invocation JWT expired during a slow upload; a fresh altool call mints
#     a new token. (tvOS ingestion has been observed to run long enough to hit
#     this where iOS/macOS don't.)
# Retry up to 3 times on those, but fail fast on a genuine validation rejection
# (UPLOAD FAILED with 90xxx) so real problems aren't masked.
attempt=1
max_attempts=3
RETRYABLE='network connection was lost|-1005|Unable to authenticate|-19209|status code 401|timed out|The request timed out|try again later|temporarily unavailable'
while :; do
    echo "::group::altool upload (tvOS) attempt ${attempt}/${max_attempts}"
    : > "$ALTOOL_LOG"
    set +e
    xcrun altool --upload-app \
        --type appletvos \
        --file "$IPA_PATH" \
        --apiKey "$APP_STORE_CONNECT_KEY_ID" \
        --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID" 2>&1 | tee "$ALTOOL_LOG"
    rc=${PIPESTATUS[0]}
    set -e
    echo "::endgroup::"

    if [ "$rc" -eq 0 ] && ! grep -q "UPLOAD FAILED" "$ALTOOL_LOG"; then
        echo "tvOS upload succeeded."
        exit 0
    fi

    # A validation rejection (asset/metadata) won't pass on retry — fail now.
    if grep -qE "UPLOAD FAILED with [0-9]+ error" "$ALTOOL_LOG" \
       && ! grep -qiE "$RETRYABLE" "$ALTOOL_LOG"; then
        echo "::error::altool reported a non-retryable UPLOAD FAILED — see log above"
        exit 1
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "::error::altool upload failed after ${attempt} attempts — see log above"
        exit 1
    fi

    if grep -qiE "$RETRYABLE" "$ALTOOL_LOG"; then
        echo "::warning::Transient upload failure on attempt ${attempt}; retrying in 20s"
        attempt=$((attempt + 1))
        sleep 20
        continue
    fi

    echo "::error::altool upload failed (exit ${rc}) — see log above"
    exit 1
done
