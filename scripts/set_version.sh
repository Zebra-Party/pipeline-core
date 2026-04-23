#!/usr/bin/env bash
# Writes a computed version + build into project.godot and
# export_presets.cfg in-place. Call after compute_version.sh.
#
# Usage: set_version.sh <semver> <build>
#   set_version.sh 1.2.3 4567

set -euo pipefail

VERSION="${1:?usage: set_version.sh <semver> <build>}"
BUILD="${2:?usage: set_version.sh <semver> <build>}"

# project.godot — config/version drives the in-game About / dateline.
if [ -f project.godot ]; then
	if grep -q '^config/version=' project.godot; then
		# Use a temp file to avoid sed -i portability issues.
		awk -v v="$VERSION" '
			/^config\/version=/ { print "config/version=\"" v "\""; next }
			{ print }
		' project.godot > project.godot.tmp
		mv project.godot.tmp project.godot
	fi
fi

# export_presets.cfg — store-facing version + build code per platform.
# We rewrite each known field by name so platforms we haven't touched
# (e.g. macOS) don't get clobbered.
if [ -f export_presets.cfg ]; then
	awk -v v="$VERSION" -v b="$BUILD" '
		/^application\/short_version=/ { print "application/short_version=\"" v "\""; next }
		/^application\/version=/        { print "application/version=\"" b "\""; next }
		/^version\/name=/               { print "version/name=\"" v "\""; next }
		/^version\/code=/               { print "version/code=" b; next }
		{ print }
	' export_presets.cfg > export_presets.cfg.tmp
	mv export_presets.cfg.tmp export_presets.cfg
fi

echo "Wrote version=$VERSION build=$BUILD"
