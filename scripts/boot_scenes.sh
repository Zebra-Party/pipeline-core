#!/usr/bin/env bash
# Boots every .tscn under SCENE_DIR and fails if anything errors.
# Catches missing nodes, broken @onready paths, and runtime parse errors
# that the editor reimport doesn't surface on its own.
#
# Env:
#   GODOT      — set by install_godot.sh
#   SCENE_DIR  — root directory to search for .tscn files (default: "scenes")

set -euo pipefail

GODOT="${GODOT:?GODOT env var not set — call install_godot.sh first}"
SCENE_DIR="${SCENE_DIR:-scenes}"

failures=0
while IFS= read -r scene; do
	name="$(basename "$scene" .tscn)"
	echo "::group::Boot $name"
	output_file="/tmp/boot_${name}.log"
	"$GODOT" --headless --quit-after 60 "res://$scene" > "$output_file" 2>&1 || true
	# Strip known-benign headless noise. FreeType's "Error loading font" and
	# the matching _ensure_cache_for_size condition errors are emitted by
	# FontFile.load() under --headless even though the fonts work fine for
	# layout — they print from C and Engine.print_error_messages can't mute
	# them. Strip before grepping so they don't trip the smoke test.
	filtered=$(grep -ivE 'FreeType: Error loading font|_ensure_cache_for_size' "$output_file" || true)
	if printf '%s\n' "$filtered" | grep -iE "SCRIPT ERROR|Parse Error|ERROR:" >/dev/null; then
		echo "❌ $name produced errors:"
		printf '%s\n' "$filtered" | grep -iE "SCRIPT ERROR|Parse Error|ERROR:"
		failures=$((failures + 1))
	else
		echo "✅ $name booted clean"
	fi
	echo "::endgroup::"
done < <(find "$SCENE_DIR" -name "*.tscn" | sort)

if [ "$failures" -gt 0 ]; then
	exit 1
fi
echo "All scenes booted clean"
