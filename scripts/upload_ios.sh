#!/usr/bin/env bash
# Uploads the built .ipa to App Store Connect via xcrun altool. The user
# decides downstream whether to release or only let it sit on TestFlight;
# we only do the upload here.

set -euo pipefail

: "${IPA_PATH:?IPA_PATH env var not set — call build_ios.sh first}"
: "${APP_STORE_CONNECT_ISSUER_ID:?missing}"
: "${APP_STORE_CONNECT_KEY_ID:?missing}"
: "${APP_STORE_CONNECT_PRIVATE_KEY_BASE64:?missing}"

KEY_DIR="$HOME/.appstoreconnect/private_keys"
KEY_PATH="$KEY_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"

mkdir -p "$KEY_DIR"
echo "$APP_STORE_CONNECT_PRIVATE_KEY_BASE64" | base64 --decode > "$KEY_PATH"
chmod 600 "$KEY_PATH"

ALTOOL_LOG=$(mktemp /tmp/altool-output.XXXXXX)
trap 'rm -f "$ALTOOL_LOG" "$KEY_PATH"' EXIT

# Retry on transient upload failures (network drops, JWT expiry mid-upload
# surfacing as 401/-19209). Each altool invocation mints a fresh token, so a
# clean re-run clears those. Fail fast on a real validation rejection.
attempt=1
max_attempts=3
RETRYABLE='network connection was lost|-1005|Unable to authenticate|-19209|status code 401|timed out|The request timed out|try again later|temporarily unavailable'
while :; do
    echo "::group::altool upload attempt ${attempt}/${max_attempts}"
    : > "$ALTOOL_LOG"
    set +e
    xcrun altool --upload-app \
        --type ios \
        --file "$IPA_PATH" \
        --apiKey "$APP_STORE_CONNECT_KEY_ID" \
        --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID" 2>&1 | tee "$ALTOOL_LOG"
    rc=${PIPESTATUS[0]}
    set -e
    echo "::endgroup::"

    if [ "$rc" -eq 0 ] && ! grep -q "UPLOAD FAILED" "$ALTOOL_LOG"; then
        echo "iOS upload succeeded."
        exit 0
    fi

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
