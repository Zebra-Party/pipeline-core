#!/usr/bin/env bash
# Runs every headless GDScript test matching TEST_PATTERN. Each script
# extends SceneTree and self-asserts; non-zero exit means failure.
#
# Env:
#   GODOT        — set by install_godot.sh
#   TEST_PATTERN — glob pattern for test scripts (default: "test/_test_*.gd")

set -euo pipefail

GODOT="${GODOT:?GODOT env var not set — call install_godot.sh first}"
TEST_PATTERN="${TEST_PATTERN:-test/_test_*.gd}"

failures=0
found=0
shopt -s nullglob globstar
for script in $TEST_PATTERN; do
	found=$((found + 1))
	echo "::group::$script"
	if ! "$GODOT" --headless --script "res://$script"; then
		echo "❌ $script failed"
		failures=$((failures + 1))
	fi
	echo "::endgroup::"
done

if [ "$found" -eq 0 ]; then
	echo "No test scripts matched '$TEST_PATTERN' — skipping"
	exit 0
fi

if [ "$failures" -gt 0 ]; then
	echo "$failures test script(s) failed"
	exit 1
fi
echo "All headless tests passed"
