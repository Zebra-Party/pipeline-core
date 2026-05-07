#!/usr/bin/env bash
# Helpers for codesigning on self-hosted macOS runners that share a user
# account.
#
# Model: each runner has its own *persistent* keychain at a stable path
# `~/Library/Keychains/zebra-ci-${RUNNER_NAME}.keychain-db`. It's built
# lazily — first time a runner runs a release job, setup_runner_keychain
# imports the cert from the GitHub secret. Every subsequent job on that
# runner just unlocks the existing keychain. If the secret rotates, the
# fingerprint mismatch triggers an automatic rebuild.
#
# What the helpers in this file still need to coordinate:
#
#   * The user's keychain SEARCH LIST is one slot shared across all
#     runners on the user. While ANY job's xcodebuild is running, the
#     search list must contain only that job's keychain (+ login),
#     otherwise xcodebuild's identity lookup may pick a sibling runner's
#     identity and codesign with --keychain mismatches and fails. The
#     codesign lock + keychain_search_list_isolate handle this.
#
#   * Concurrent search-list mutations need a lightweight mutex
#     (`mkdir`-based, since `flock(1)` isn't available on macOS).
#
# What this file no longer does (vs. the per-job-keychain era):
#
#   * No per-job keychain creation/destruction → no `keychain_destroy`,
#     no `keychain_search_list_remove`, no parser for `security
#     list-keychains` output.
#   * No per-job `set-key-partition-list` race → no smoke test, no
#     smoke retry.
#   * No `default-keychain` writes per job → no trustd loop on cleanup.

set -euo pipefail

_KEYCHAIN_LOCK_DIR="/tmp/zebra-keychain-search-list.${USER:-$(whoami)}.lock.d"
_KEYCHAIN_LOCK_TIMEOUT_TENTHS=600 # 60 seconds
_KEYCHAIN_CODESIGN_LOCK="/tmp/zebra-codesign.${USER:-$(whoami)}.lock"

_keychain_acquire_lock() {
    local i=0
    while ! mkdir "$_KEYCHAIN_LOCK_DIR" 2>/dev/null; do
        # Break stale locks left by killed runners.
        if [ -f "$_KEYCHAIN_LOCK_DIR/pid" ]; then
            local owner
            owner=$(cat "$_KEYCHAIN_LOCK_DIR/pid" 2>/dev/null || true)
            if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
                rm -rf "$_KEYCHAIN_LOCK_DIR"
                continue
            fi
        fi
        sleep 0.1
        i=$((i + 1))
        if [ "$i" -ge "$_KEYCHAIN_LOCK_TIMEOUT_TENTHS" ]; then
            echo "::warning::keychain search-list lock timeout — proceeding without lock" >&2
            return 0
        fi
    done
    echo $$ >"$_KEYCHAIN_LOCK_DIR/pid"
}

_keychain_release_lock() {
    rm -rf "$_KEYCHAIN_LOCK_DIR"
}

# keychain_search_list_isolate <keychain_path>
# Replace the user's search list with exactly [<keychain_path>, login.keychain-db].
# Called from inside the host-wide codesign lock so xcodebuild's identity
# lookup finds only this runner's signing identity, not a sibling runner's
# (all per-runner keychains hold the same Apple Distribution cert imported
# from the same GitHub secret, so search-list order would otherwise pick
# the wrong one).
keychain_search_list_isolate() {
    local kc="${1:?keychain path required}"
    _keychain_acquire_lock
    local rc=0
    {
        local login_kc="$HOME/Library/Keychains/login.keychain-db"
        if [ -e "$login_kc" ]; then
            security list-keychains -d user -s "$kc" "$login_kc"
        else
            security list-keychains -d user -s "$kc"
        fi
    } || rc=$?
    _keychain_release_lock
    return $rc
}

# keychain_codesign_lock_acquire
# Block until this build holds the host-wide codesign lock, then install
# an EXIT trap that releases it. Call this BEFORE the first signing
# operation (Godot --export-release, xcodebuild archive, codesign,
# productbuild). Other runners' jobs queue here so only one is in the
# search-list-isolated codesign window at a time.
#
# Uses shlock(1) (BSD/macOS, atomic via link(2), PID-aware so a
# hard-killed prior build doesn't deadlock the next one).
#
# Override timeout via KEYCHAIN_CODESIGN_LOCK_TIMEOUT (seconds, default 1200).
keychain_codesign_lock_acquire() {
    local timeout="${KEYCHAIN_CODESIGN_LOCK_TIMEOUT:-1200}"
    local deadline=$((SECONDS + timeout))
    echo "Acquiring codesign lock at $_KEYCHAIN_CODESIGN_LOCK..."
    until shlock -p $$ -f "$_KEYCHAIN_CODESIGN_LOCK" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "::error::Failed to acquire codesign lock within ${timeout}s — is another build hung?"
            exit 1
        fi
        sleep 2
    done
    trap 'keychain_codesign_lock_release' EXIT
    echo "Codesign lock acquired (held until script exit)."
}

keychain_codesign_lock_release() {
    rm -f "$_KEYCHAIN_CODESIGN_LOCK"
}

# keychain_import_apple_intermediates <keychain_path>
# Codesign with `--keychain PATH` only searches that keychain for the
# leaf cert *and its trust chain*. The Apple WWDR / Apple Root
# intermediates live in the system keychain on macOS; without copying
# them into the build keychain, the chain Distribution → WWDR → Apple
# Root fails to assemble locally and codesign returns
# errSecInternalComponent.
keychain_import_apple_intermediates() {
    local kc="${1:?keychain path required}"
    local sysk="/Library/Keychains/System.keychain"
    local rootk="/System/Library/Keychains/SystemRootCertificates.keychain"
    local tmp
    tmp=$(mktemp -d)
    local imported=0
    local pair pattern src pem
    for pair in \
            "Apple Worldwide Developer Relations:$sysk" \
            "Developer ID Certification Authority:$sysk" \
            "Apple Application Integration:$sysk" \
            "Apple Root CA:$rootk"; do
        pattern="${pair%:*}"
        src="${pair##*:}"
        pem="$tmp/$(echo "$pattern" | tr ' /-' '___').pem"
        if security find-certificate -a -p -c "$pattern" "$src" >"$pem" 2>/dev/null \
            && [ -s "$pem" ]; then
            local count
            count=$(grep -c 'BEGIN CERTIFICATE' "$pem" || echo 0)
            if security import "$pem" -k "$kc" -A 2>/dev/null; then
                imported=$((imported + count))
            fi
        fi
    done
    rm -rf "$tmp"
    echo "Imported $imported Apple intermediate / root certificates into $kc"
}

# _keychain_p12_sha1 <p12_path> <p12_password>
# Echo the leaf certificate's SHA-1 fingerprint (uppercase hex, no separators).
# The fingerprint is what `security find-identity` shows — used to compare
# what's in the secret vs. what's already in the runner's keychain.
_keychain_p12_sha1() {
    local p12="${1:?}" pw="${2:?}"
    openssl pkcs12 -nokeys -nomacver -in "$p12" -passin "pass:$pw" 2>/dev/null \
        | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
        | sed 's/.*=//;s/://g'
}

# _keychain_first_identity_sha1 <keychain_path> <name_pattern>
# Echo the SHA-1 of the first identity in <keychain_path> whose certificate
# common name matches <name_pattern>. Empty if none / not unlockable.
_keychain_first_identity_sha1() {
    local kc="${1:?}" pattern="${2:?}"
    security find-identity -v -p codesigning "$kc" 2>/dev/null \
        | grep -E "$pattern" | head -1 | awk '{print $2}'
}

# setup_runner_keychain
# Idempotently ensure the per-runner persistent keychain is built and
# contains the current Apple Distribution certificate (and optional
# Mac Installer Distribution certificate).
#
# Required env:
#   APPLE_CERTIFICATE_P12_BASE64    — base64-encoded distribution .p12
#   APPLE_CERTIFICATE_PASSWORD      — its password (also reused as the
#                                     keychain password — stable across jobs)
#
# Optional env:
#   APPLE_MAC_INSTALLER_P12_BASE64  — base64-encoded installer .p12;
#                                     imported alongside the distribution
#                                     cert when present (macOS .pkg signing)
#
# Echoes the keychain path on stdout. Caller captures it as KEYCHAIN_PATH.
setup_runner_keychain() {
    : "${APPLE_CERTIFICATE_P12_BASE64:?missing APPLE_CERTIFICATE_P12_BASE64}"
    : "${APPLE_CERTIFICATE_PASSWORD:?missing APPLE_CERTIFICATE_PASSWORD}"

    local runner kc pw
    runner="${RUNNER_NAME:-$(hostname -s)}"
    kc="$HOME/Library/Keychains/zebra-ci-${runner}.keychain-db"
    pw="$APPLE_CERTIFICATE_PASSWORD"
    mkdir -p "$HOME/Library/Keychains"

    # Decode the secret to a temp .p12 just long enough to fingerprint /
    # import. Cleaned up on exit.
    local tmp_p12 expected_sha1
    tmp_p12=$(mktemp -t zebra-cert.XXXXXX)
    trap 'rm -f "$tmp_p12"' RETURN
    echo "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$tmp_p12"
    expected_sha1=$(_keychain_p12_sha1 "$tmp_p12" "$pw")
    if [ -z "$expected_sha1" ]; then
        echo "::error::Could not extract SHA-1 from APPLE_CERTIFICATE_P12_BASE64 (wrong APPLE_CERTIFICATE_PASSWORD?)" >&2
        return 1
    fi

    # Decide: rebuild or reuse?
    local need_rebuild=1 have_sha1=""
    if [ -f "$kc" ] && security unlock-keychain -p "$pw" "$kc" 2>/dev/null; then
        have_sha1=$(_keychain_first_identity_sha1 "$kc" "Apple Distribution")
        [ "$expected_sha1" = "$have_sha1" ] && need_rebuild=0
    fi

    if [ "$need_rebuild" -eq 1 ]; then
        echo "Building runner keychain at $kc"
        echo "  expected sha1: $expected_sha1"
        echo "  have sha1:     ${have_sha1:-(none)}"
        # Tear down any stale state. Both calls tolerate "doesn't exist".
        security delete-keychain "$kc" 2>/dev/null || true
        rm -f "$kc"
        # Create. Same password as the .p12 so we don't need a separate secret.
        security create-keychain -p "$pw" "$kc"
        # No -t (idle timeout) and no -l (lock-on-sleep): the keychain
        # stays unlocked between jobs so subsequent jobs only need to
        # detect that fact, not unlock again.
        security set-keychain-settings "$kc"
        security unlock-keychain -p "$pw" "$kc"
        # Import the distribution cert. -A allows any tool to access the
        # private key without prompting; the explicit -T entries pre-trust
        # the tools that codesign relies on.
        security import "$tmp_p12" -k "$kc" -P "$pw" \
            -A -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcodebuild
        security set-key-partition-list -S "apple-tool:,apple:,codesign:" \
            -s -k "$pw" "$kc" >/dev/null
        # Apple intermediates so the chain validates inside this kc.
        keychain_import_apple_intermediates "$kc"
    else
        echo "Reusing runner keychain at $kc (sha1 $have_sha1)"
    fi

    # Optional Mac Installer cert. Imported into the same kc so productbuild
    # finds it. Idempotent — only re-imports if missing or fingerprint changed.
    if [ -n "${APPLE_MAC_INSTALLER_P12_BASE64:-}" ]; then
        local tmp_inst expected_inst_sha1 have_inst_sha1
        tmp_inst=$(mktemp -t zebra-installer.XXXXXX)
        echo "$APPLE_MAC_INSTALLER_P12_BASE64" | base64 --decode > "$tmp_inst"
        expected_inst_sha1=$(_keychain_p12_sha1 "$tmp_inst" "$pw")
        have_inst_sha1=$(_keychain_first_identity_sha1 "$kc" "3rd Party Mac Developer Installer|Mac Installer Distribution")
        if [ -n "$expected_inst_sha1" ] && [ "$expected_inst_sha1" != "$have_inst_sha1" ]; then
            echo "Updating Mac Installer cert in $kc"
            echo "  expected sha1: $expected_inst_sha1"
            echo "  have sha1:     ${have_inst_sha1:-(none)}"
            if [ -n "$have_inst_sha1" ]; then
                security delete-identity -Z "$have_inst_sha1" "$kc" 2>/dev/null || true
            fi
            security import "$tmp_inst" -k "$kc" -P "$pw" -A
            security set-key-partition-list -S "apple-tool:,apple:,codesign:,productbuild:" \
                -s -k "$pw" "$kc" >/dev/null
        fi
        rm -f "$tmp_inst"
    fi

    # Ensure unlocked (defensive — a system event could have locked it).
    security unlock-keychain -p "$pw" "$kc" 2>/dev/null || true

    printf '%s\n' "$kc"
}
