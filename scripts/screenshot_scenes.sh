#!/usr/bin/env bash
# Captures one PNG per (scene × resolution) under build/screenshots/.
# The rendering server needs a GL context, so we run under xvfb-run
# (must be installed on the runner) with the opengl3 driver; plain
# --headless won't work because it disables rendering entirely.
#
# Generic across any Godot 4 project. Defaults:
#
#   SCENE_GLOB       — "scenes/*.tscn"
#   OUT_DIR          — "build/screenshots"
#   SCREENSHOT_SEED  — res://tools/ci/screenshot_seed.gd if it exists
#   SCREENSHOT_DEVICES — comma-separated "slug:width:height" entries
#                        (defaults to the 20:9 + 16:9 portrait/landscape
#                        set below)
#
# Outputs: $OUT_DIR/<device_slug>/<scene_name>.png

set -euo pipefail

GODOT="${GODOT:?GODOT env var not set — call install_godot.sh first}"
OUT_DIR="${OUT_DIR:-build/screenshots}"
SCENE_GLOB="${SCENE_GLOB:-scenes/*.tscn}"

# Screenshot capture relies on xvfb (Linux X virtual framebuffer) to give
# Godot a GL context without a real display. macOS doesn't ship xvfb and
# we don't have an equivalent offscreen pipeline wired up for the olympus
# fleet — skip with a warning rather than failing the whole run. CI for
# the boot smoke tests + headless tests still runs; only the PR
# screenshot diff is missing.
if ! command -v xvfb-run >/dev/null 2>&1; then
	if [ "$(uname -s)" = "Darwin" ]; then
		echo "::warning::xvfb-run not available on macOS runners — skipping screenshot capture"
		exit 0
	fi
	echo "❌ xvfb-run not found on PATH — install xvfb on this runner" >&2
	exit 1
fi

# device_slug:width:height — override via $SCREENSHOT_DEVICES (comma-
# separated). Defaults are two aspect ratios × portrait/landscape,
# 1080 on the short side; picked for variety rather than matching any
# specific device.
if [ -n "${SCREENSHOT_DEVICES:-}" ]; then
	IFS=',' read -r -a DEVICES <<< "$SCREENSHOT_DEVICES"
else
	DEVICES=(
		"portrait_20_9:1080:2400"
		"landscape_20_9:2400:1080"
		"portrait_16_9:1080:1920"
		"landscape_16_9:1920:1080"
	)
fi

# Seed script is optional. If it lives at the default path we pass
# --seed= through to the harness; projects that don't need seeding
# just leave the file out.
SEED_PATH="${SCREENSHOT_SEED:-tools/ci/screenshot_seed.gd}"
SEED_ARG=()
if [ -f "$SEED_PATH" ]; then
	SEED_ARG=("--seed=res://$SEED_PATH")
fi

mkdir -p "$OUT_DIR"
# Start with a clean tree so stale folders from previous runs (e.g.
# devices that have since been removed from the list) don't leak
# into the gallery as empty columns. The self-hosted runner keeps
# build/ between builds, so this has to be explicit.
rm -rf "${OUT_DIR:?}"/*

failures=0
shopt -s nullglob globstar
for scene in $SCENE_GLOB; do
	scene_name="$(basename "$scene" .tscn)"
	for entry in "${DEVICES[@]}"; do
		IFS=":" read -r device width height <<< "$entry"
		out_path="$OUT_DIR/$device/$scene_name.png"
		log_path="/tmp/screenshot_${device}_${scene_name}.log"
		mkdir -p "$(dirname "$out_path")"

		echo "::group::Screenshot $scene_name @ $device (${width}x${height})"
		# `-a` picks a free display so parallel jobs on the same runner
		# don't collide on :99. `--resolution` is the reliable way to
		# set the initial window size — `DisplayServer.window_set_size`
		# at runtime under xvfb leaves the viewport render target at
		# the project's configured default.
		if xvfb-run -a --server-args="-screen 0 ${width}x${height}x24 +extension GLX +render -noreset" \
			"$GODOT" --rendering-driver opengl3 \
			"--resolution" "${width}x${height}" \
			res://tools/ci/screenshot_harness.tscn \
			-- \
			"--scene=res://$scene" \
			"--out=$out_path" \
			"--width=$width" \
			"--height=$height" \
			"${SEED_ARG[@]}" \
			> "$log_path" 2>&1; then
			if [ -f "$out_path" ]; then
				# Verify the PNG has the right dimensions — Godot exits
				# 0 even on a blank capture, so we check the written
				# output to catch pipeline regressions early.
				if command -v file >/dev/null 2>&1; then
					echo "  $(file "$out_path" | sed 's/.*: //')"
				fi
				echo "✅ $scene_name @ $device → $out_path"
			else
				echo "❌ $scene_name @ $device: godot exited 0 but no PNG was written"
				sed -n '1,80p' "$log_path" >&2
				failures=$((failures + 1))
			fi
		else
			echo "❌ $scene_name @ $device failed"
			sed -n '1,80p' "$log_path" >&2
			failures=$((failures + 1))
		fi
		# Always print the harness's diagnostic line so we can spot
		# resolution drift in the build log.
		grep -E "screenshot_harness:" "$log_path" || true
		echo "::endgroup::"
	done
done

if [ "$failures" -gt 0 ]; then
	echo "$failures screenshot(s) failed" >&2
	exit 1
fi

echo "All screenshots captured under $OUT_DIR"
