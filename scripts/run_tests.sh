#!/usr/bin/env bash
# Runs every headless GDScript test matching TEST_PATTERN. Each script
# extends SceneTree and self-asserts; non-zero exit means failure.
#
# Env:
#   GODOT                 — set by install_godot.sh
#   TEST_PATTERN          — glob for test scripts (default: "test/_test_*.gd")
#   STRICT_SCRIPT_ERRORS  — "1" to also fail a test that prints "SCRIPT ERROR"
#                           even though it exited 0. Catches the false-pass
#                           where a swallowed compile/runtime error aborts a
#                           test function before it can record a failure, so
#                           the suite still reports success. Default off so
#                           existing consumers are unaffected; opt in per repo.

set -euo pipefail

GODOT="${GODOT:?GODOT env var not set — call install_godot.sh first}"
TEST_PATTERN="${TEST_PATTERN:-test/_test_*.gd}"
STRICT_SCRIPT_ERRORS="${STRICT_SCRIPT_ERRORS:-0}"

failures=0
found=0
shopt -s nullglob
for script in $TEST_PATTERN; do
	found=$((found + 1))
	echo "::group::$script"
	# Capture output so we can stream it and, in strict mode, scan it for
	# engine errors that slipped past a 0 exit code.
	if out="$("$GODOT" --headless --script "res://$script" 2>&1)"; then
		printf '%s\n' "$out"
		if [ "$STRICT_SCRIPT_ERRORS" = "1" ] && printf '%s' "$out" | grep -q "SCRIPT ERROR"; then
			echo "❌ $script printed SCRIPT ERROR despite exiting 0 — likely a swallowed false pass"
			failures=$((failures + 1))
		fi
	else
		printf '%s\n' "$out"
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
