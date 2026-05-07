#!/usr/bin/env bash
# Helpers for parallel-safe keychain handling on self-hosted macOS runners.
#
# Multiple GitHub Actions runners on a single user account share one
# keychain search list (`security list-keychains -d user`) and one
# default keychain. Concurrent jobs that read-modify-write either of
# those will race. The fixes here are:
#
#   1. Each job gets its own keychain at a unique path so two jobs never
#      open the same keychain file at once.
#   2. Search-list mutations are wrapped in a per-user mkdir mutex so
#      concurrent rewrites serialise. (`flock(1)` is not on macOS;
#      mkdir is atomic on POSIX and needs no extra tooling.)
#   3. The *default* keychain is a single-slot piece of global state.
#      We do still set it (some code paths inside Xcode reach for the
#      default even when we pass --keychain explicitly — empirically
#      that's what trips errSecInternalComponent in xcodebuild's archive
#      step on multi-runner setups). It's set under the same mutex.
#      On cleanup we MUST restore the default back to the user's login
#      keychain — leaving the default pointing at a deleted per-job
#      keychain causes trustd / identityservicesd to spin in a tight
#      retry loop on long-lived self-hosted runners, pegging CPU and
#      blocking TLS handshakes (including the runner listener's own
#      long-poll, which is then marked offline by GitHub).

set -euo pipefail

_KEYCHAIN_LOCK_DIR="/tmp/zebra-keychain-search-list.${USER:-$(whoami)}.lock.d"
_KEYCHAIN_LOCK_TIMEOUT_TENTHS=600 # 60 seconds

# Host-wide codesign lock — prevents two concurrent runners from
# trampling each other's `security default-keychain -s` mid-build.
# Held for the duration of one build's signing window (assertion +
# Godot/xcodebuild export). Uses shlock(1) (BSD/macOS, atomic via
# link(2), PID-aware so a hard-killed prior build doesn't deadlock
# the next one).
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

# keychain_unique_path <prefix>
# Echoes a fresh keychain path under ~/Library/Keychains/. Includes the
# runner name + run id + run attempt + a random suffix so two jobs on
# the same runner machine (or two attempts of the same run) never
# collide. Keychains must live under ~/Library/Keychains/ on macOS 14+
# or securityd refuses to write to them.
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

# keychain_search_list_add <keychain_path>
# Adds the keychain to the user's search list under the mutex.
# Idempotent — does nothing if the path is already present.
keychain_search_list_add() {
    local kc="${1:?keychain path required}"
    _keychain_acquire_lock
    local rc=0
    {
        local existing
        existing=$(security list-keychains -d user 2>/dev/null \
            | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
        if printf '%s\n' "$existing" | grep -qxF "$kc"; then
            :
        else
            # shellcheck disable=SC2086  # word-split is intentional
            security list-keychains -d user -s "$kc" $existing
        fi
    } || rc=$?
    _keychain_release_lock
    return $rc
}

# keychain_search_list_remove <keychain_path>
# Removes the keychain from the user's search list under the mutex.
keychain_search_list_remove() {
    local kc="${1:?keychain path required}"
    _keychain_acquire_lock
    local rc=0
    {
        local kept=()
        local line
        while IFS= read -r line; do
            line="${line//\"/}"
            line="${line## }"
            line="${line%% }"
            [ -z "$line" ] && continue
            [ "$line" = "$kc" ] && continue
            kept+=("$line")
        done < <(security list-keychains -d user 2>/dev/null || true)
        if [ "${#kept[@]}" -eq 0 ]; then
            security list-keychains -d user -s
        else
            security list-keychains -d user -s "${kept[@]}"
        fi
    } || rc=$?
    _keychain_release_lock
    return $rc
}

# keychain_import_apple_intermediates <keychain_path>
# Codesign with `--keychain PATH` only searches that keychain for the
# leaf cert *and its trust chain*. The Apple WWDR / DEV-ID-CS / G6
# intermediates live in /Library/Keychains/System.keychain on macOS;
# without copying them into the build keychain, the chain Distribution
# -> WWDR -> Apple Root fails to assemble and codesign returns
# errSecInternalComponent. Extract everything Apple-issued from the
# system keychain in PEM form and re-import into the build keychain
# so the chain validates locally.
keychain_import_apple_intermediates() {
    local kc="${1:?keychain path required}"
    local sysk="/Library/Keychains/System.keychain"
    local rootk="/System/Library/Keychains/SystemRootCertificates.keychain"
    local tmp
    tmp=$(mktemp -d)
    local imported=0
    # Pull every Apple-issued cert (intermediates + every Apple Root
    # generation) so the chain Distribution → WWDR-of-some-generation →
    # Apple-Root-of-some-generation always assembles inside this keychain.
    # `-a -p` emits multiple PEMs concatenated; security import handles
    # multi-cert PEM bundles fine.
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

# keychain_assert_active <keychain_path> <password>
# Brief critical section that re-establishes the build keychain as
# usable for the next xcodebuild step:
#   - unlocks it (must be done before the partition list is queried)
#   - ensures it's on the user's search list
#   - sets it as the user's default keychain
#
# The default-keychain mutation is global, so concurrent runners race
# on it — but the actual signing calls all pass --keychain explicitly,
# so the default-keychain set is purely a fallback for legacy code
# paths inside Xcode that ignore --keychain (which is what historically
# triggered errSecInternalComponent on this codebase).
keychain_assert_active() {
    local kc="${1:?keychain path required}"
    local pw="${2:?keychain password required}"
    security unlock-keychain -p "$pw" "$kc"
    _keychain_acquire_lock
    {
        local existing
        existing=$(security list-keychains -d user 2>/dev/null \
            | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
        if ! printf '%s\n' "$existing" | grep -qxF "$kc"; then
            # shellcheck disable=SC2086  # word-split is intentional
            security list-keychains -d user -s "$kc" $existing 2>/dev/null || true
        fi
        security default-keychain -s "$kc" 2>/dev/null || true
    } || true
    _keychain_release_lock
}

# keychain_codesign_lock_acquire
# Block until this build holds the host-wide codesign lock, then
# install an EXIT trap that releases it. Call this AFTER
# keychain_assert_active and BEFORE any signing operation
# (Godot --export-release, xcodebuild archive, codesign, productbuild).
# Sibling runners will queue up here so only one is in the
# "default-keychain points at me" + "codesign running" window at a time.
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
    # Use a function-level trap so callers don't have to remember to
    # release. If the caller already has its own EXIT trap, append.
    trap 'keychain_codesign_lock_release' EXIT
    echo "Codesign lock acquired (held until script exit)."
}

keychain_codesign_lock_release() {
    rm -f "$_KEYCHAIN_CODESIGN_LOCK"
}

# keychain_destroy <keychain_path>
# Removes from search list, restores the user's default keychain if it
# pointed at $kc, deletes the keychain, unlinks the file.
# Safe to call from cleanup steps with `if: always()`.
keychain_destroy() {
    local kc="${1:-}"
    [ -z "$kc" ] && return 0
    keychain_search_list_remove "$kc" 2>/dev/null || true
    _keychain_acquire_lock
    {
        local cur_default
        cur_default=$(security default-keychain -d user 2>/dev/null \
            | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
        if [ "$cur_default" = "$kc" ]; then
            local login_kc="$HOME/Library/Keychains/login.keychain-db"
            if [ -e "$login_kc" ]; then
                security default-keychain -s "$login_kc" 2>/dev/null || true
            else
                # No login keychain to fall back on — clear the slot
                # rather than leaving it pointing at a doomed file.
                security default-keychain -s 2>/dev/null || true
            fi
        fi
    } || true
    _keychain_release_lock
    security delete-keychain "$kc" 2>/dev/null || true
    rm -f "$kc"
}
