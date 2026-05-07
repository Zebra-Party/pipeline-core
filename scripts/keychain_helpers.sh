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
#   3. Nothing here ever touches the *default* keychain — that's a
#      single-slot piece of global state. xcodebuild gets the keychain
#      via OTHER_CODE_SIGN_FLAGS=--keychain, direct codesign /
#      productbuild calls pass --keychain explicitly. Godot's iOS
#      exporter finds the cert via the search list.

set -euo pipefail

_KEYCHAIN_LOCK_DIR="/tmp/zebra-keychain-search-list.${USER:-$(whoami)}.lock.d"
_KEYCHAIN_LOCK_TIMEOUT_TENTHS=600 # 60 seconds

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

# keychain_destroy <keychain_path>
# Removes from search list, deletes the keychain, unlinks the file.
# Safe to call from cleanup steps with `if: always()`.
keychain_destroy() {
    local kc="${1:-}"
    [ -z "$kc" ] && return 0
    keychain_search_list_remove "$kc" 2>/dev/null || true
    security delete-keychain "$kc" 2>/dev/null || true
    rm -f "$kc"
}
