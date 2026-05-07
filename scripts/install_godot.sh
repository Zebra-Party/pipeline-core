#!/usr/bin/env bash
# Installs Godot + matching export templates into a per-runner cache so
# subsequent runs are fast. Honours $GODOT_VERSION (defaults to 4.6.2-stable).
#
# Exposes:
#   $GODOT       — full path to the headless-capable Godot binary
#   $GODOT_HOME  — cache root (writable, persisted on self-hosted runners)
#
# When sourced from a workflow step, the GITHUB_ENV writes propagate the
# variables to subsequent steps.

set -euo pipefail

GODOT_VERSION="${1:-${GODOT_VERSION:-4.6.2-stable}}"
GODOT_HOME="${GODOT_HOME:-${RUNNER_TOOL_CACHE:-$HOME/.cache}/godot}"
mkdir -p "$GODOT_HOME"

OS_KIND=""
case "$(uname -s)" in
	Darwin) OS_KIND="macos" ;;
	Linux) OS_KIND="linux" ;;
	*) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

bin_dir="$GODOT_HOME/$GODOT_VERSION"
mkdir -p "$bin_dir"

godot_path=""
case "$OS_KIND" in
	macos)
		godot_path="$bin_dir/Godot.app/Contents/MacOS/Godot"
		if [ ! -x "$godot_path" ]; then
			echo "Downloading Godot $GODOT_VERSION (macOS)…"
			curl -fsSL -o "$bin_dir/godot.zip" \
				"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_macos.universal.zip"
			python3 -m zipfile -e "$bin_dir/godot.zip" "$bin_dir/"
			rm "$bin_dir/godot.zip"
			# Python's zipfile module drops Unix permission bits on extract,
			# so the inner binary is non-executable; restore it.
			chmod +x "$godot_path"
		fi
		# Strip Gatekeeper quarantine so the unsigned-by-us bundle launches
		# headlessly without the "downloaded from internet" prompt.
		xattr -dr com.apple.quarantine "$bin_dir/Godot.app" 2>/dev/null || true
		;;
	linux)
		godot_path="$bin_dir/godot"
		if [ ! -x "$godot_path" ]; then
			echo "Downloading Godot $GODOT_VERSION (Linux headless)…"
			curl -fsSL -o "$bin_dir/godot.zip" \
				"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"
			python3 -m zipfile -e "$bin_dir/godot.zip" "$bin_dir/"
			mv "$bin_dir/Godot_v${GODOT_VERSION}_linux.x86_64" "$godot_path"
			chmod +x "$godot_path"
			rm "$bin_dir/godot.zip"
		fi
		;;
esac

# Export templates — required for `--export-release`. Path varies per OS.
templates_dir=""
case "$OS_KIND" in
	macos) templates_dir="$HOME/Library/Application Support/Godot/export_templates/${GODOT_VERSION/-stable/.stable}" ;;
	linux) templates_dir="$HOME/.local/share/godot/export_templates/${GODOT_VERSION/-stable/.stable}" ;;
esac
# Re-extract if the dir is missing entirely OR if it exists but is missing
# a key per-platform file — earlier runs sometimes left a partial install
# behind (e.g. after a botched extract) and we want to recover automatically.
needs_install=false
if [ ! -d "$templates_dir" ] || [ -z "$(ls -A "$templates_dir" 2>/dev/null)" ]; then
	needs_install=true
elif [ "$OS_KIND" = "macos" ] && [ ! -f "$templates_dir/ios.zip" ]; then
	echo "Templates dir exists but ios.zip is missing — re-extracting."
	needs_install=true
fi

if [ "$needs_install" = "true" ]; then
	echo "Downloading export templates ${GODOT_VERSION}…"
	mkdir -p "$templates_dir"
	curl -fsSL -o "$bin_dir/templates.tpz" \
		"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_export_templates.tpz"
	rm -rf "$bin_dir/templates_unpack"
	python3 -m zipfile -e "$bin_dir/templates.tpz" "$bin_dir/templates_unpack/"
	if [ ! -d "$bin_dir/templates_unpack/templates" ]; then
		echo "::error::tpz layout unexpected — no top-level templates/ dir. Found:"
		ls -la "$bin_dir/templates_unpack" || true
		exit 1
	fi
	cp -R "$bin_dir/templates_unpack/templates/." "$templates_dir/"
	rm -rf "$bin_dir/templates_unpack" "$bin_dir/templates.tpz"
	echo "Installed templates:"
	ls -la "$templates_dir" | sed 's/^/  /'
fi

echo "Godot binary: $godot_path"
echo "Templates dir: $templates_dir"

if [ -n "${GITHUB_ENV:-}" ]; then
	echo "GODOT=$godot_path" >> "$GITHUB_ENV"
	echo "GODOT_HOME=$GODOT_HOME" >> "$GITHUB_ENV"
fi
