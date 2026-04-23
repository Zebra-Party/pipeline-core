#!/usr/bin/env bash
# Primes Godot's asset imports so `.godot/imported/*` sidecars exist,
# class_name globals register, and the filesystem scan finishes before
# any export step runs.
#
# We use `--quit-after 60` rather than `--quit` because the iOS
# exporter in 4.6 silently validates against the state of
# `.godot/imported/`, and a bare `--quit` kills Godot before the scan
# has time to land everything on disk. This matches the "prime" step
# that works in another Godot 4.6 project shipping from CI.

set -uo pipefail

GODOT="${GODOT:?GODOT env var not set — call install_godot.sh first}"

LOG=/tmp/godot_import.log

"$GODOT" --headless --editor --path . --quit-after 60 > "$LOG" 2>&1
status=$?

if [ "$status" -eq 0 ] && grep -qiE "Could not find type|Identifier .* not declared" "$LOG"; then
	echo "class_name registration didn't settle on the first pass, retrying once…"
	"$GODOT" --headless --editor --path . --quit-after 60 > "$LOG" 2>&1
	status=$?
fi

echo "::group::Godot output (last 40 lines)"
tail -40 "$LOG" || true
echo "::endgroup::"

if [ "$status" -ne 0 ]; then
	echo "Godot reimport exited $status"
	exit "$status"
fi

if grep -iE "Parse Error|SCRIPT ERROR" "$LOG"; then
	echo "Reimport surfaced parse errors above."
	exit 1
fi
echo "Reimport completed clean"
