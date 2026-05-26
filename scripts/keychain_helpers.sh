#!/usr/bin/env bash
# Helpers for ephemeral per-job signing keychains on self-hosted macOS
# runners.
#
# Each release job creates a keychain at a unique path, imports the
# Apple Distribution cert from a GitHub secret, signs, and destroys the
# keychain in an `if: always()` cleanup step. Nothing secret persists on
# the host between jobs.
#
# Each runner runs under its own macOS user account, so the user-domain
# search list and default-keychain slot have no other clients — no
# cross-runner mutex / lock coordination is needed.

set -euo pipefail

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# keychain_unique_path <prefix>
# Echoes a fresh keychain path under ~/Library/Keychains/. Includes the
# runner name + run id + run attempt + a random suffix so two attempts
# of the same run never collide. Keychains must live under
# ~/Library/Keychains/ on macOS 14+ or securityd refuses to write to them.
keychain_unique_path() {
    local prefix="${1:?prefix required}"
    local runner="${RUNNER_NAME:-$(hostname -s)}"
    local run="${GITHUB_RUN_ID:-$$}"
    local attempt="${GITHUB_RUN_ATTEMPT:-1}"
    local rand
    rand="$(openssl rand -hex 4)"
    mkdir -p "$HOME/Library/Keychains"
    printf '%s/Library/Keychains/%s-%s-%s-%s-%s.keychain-db\n' \
        "$HOME" "$prefix" "$runner" "$run" "$attempt" "$rand"
}

# keychain_activate <keychain_path> <password>
# Unlocks the keychain, places it at the front of the user-domain search
# list (login.keychain-db kept behind it for any user-installed Apple
# intermediates), and pins it as the user's default keychain. Required
# because Godot's exporters and parts of xcodebuild's archive step shell
# out to codesign without --keychain and fall back to the search list /
# default keychain.
#
# Build keychain is the SOLE entry in the user search list during the
# build — login.keychain-db is excluded. This is intentional:
# `keychain_import_apple_intermediates` plus the apple.com cert
# backstop guarantee the build keychain contains every intermediate
# and root we need, so codesign has no reason to look elsewhere.
# Including login.keychain-db has been observed to cause
# errSecInternalComponent on runners that have stale Apple Distribution
# leaf certs or older WWDR intermediates left over from previous runs:
# codesign picks the stale leaf, can't match it to a current
# intermediate, and aborts. Build cleanup (keychain_destroy) puts
# login.keychain-db back as the default after the build.
keychain_activate() {
    local kc="${1:?keychain path required}"
    local pw="${2:?keychain password required}"
    security unlock-keychain -p "$pw" "$kc"
    security list-keychains -d user -s "$kc"
    security default-keychain -s "$kc"
}

# keychain_import_apple_intermediates <keychain_path>
# Codesign with `--keychain PATH` only searches that keychain for the
# leaf cert and its trust chain. The Apple WWDR / DEV-ID-CS / G6
# intermediates live in /Library/Keychains/System.keychain on macOS;
# without copying them into the build keychain, the chain Distribution
# -> WWDR -> Apple Root fails to assemble and codesign returns
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

    # Belt-and-braces: also fetch the current Apple intermediates straight
    # from Apple's certificate authority page. Some self-hosted runners
    # have stale or incomplete System.keychains (specifically observed on
    # an Olympus runner missing AppleWWDRCAG6) and the chain build then
    # fails with errSecInternalComponent / "unable to build chain to
    # self-signed root". These fetches are idempotent — re-importing a
    # cert already in the keychain is a no-op.
    local cer
    for url in \
            "https://www.apple.com/certificateauthority/AppleWWDRCAG6.cer" \
            "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer" \
            "https://www.apple.com/certificateauthority/AppleIncRootCertificate.cer" \
            "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer"; do
        cer="$tmp/$(basename "$url")"
        if curl -fsSL --connect-timeout 10 --max-time 30 -o "$cer" "$url" \
            && [ -s "$cer" ]; then
            if security import "$cer" -k "$kc" -A 2>/dev/null; then
                imported=$((imported + 1))
            fi
        else
            echo "warning: failed to fetch $url; relying on System.keychain copy" >&2
        fi
    done

    rm -rf "$tmp"
    echo "Imported $imported Apple intermediate / root certificates into $kc"
}

# keychain_destroy <keychain_path>
# Restores the login keychain as the user's default and only entry on
# the search list, then deletes the per-job build keychain. Safe to
# call from cleanup steps with `if: always()` — every operation
# tolerates a missing/already-clean state.
keychain_destroy() {
    local kc="${1:-}"
    [ -z "$kc" ] && return 0
    if [ -e "$LOGIN_KEYCHAIN" ]; then
        security default-keychain -s "$LOGIN_KEYCHAIN" 2>/dev/null || true
        security list-keychains -d user -s "$LOGIN_KEYCHAIN" 2>/dev/null || true
    fi
    security delete-keychain "$kc" 2>/dev/null || true
    rm -f "$kc"
}
