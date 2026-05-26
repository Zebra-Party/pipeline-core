#!/usr/bin/env bash
# Regenerates the Xcode project from project.yml using XcodeGen, if a
# project.yml exists at the repo root. No-op for projects that don't
# use XcodeGen.
#
# Why this matters: consumer repos commit the generated .xcodeproj so
# local clones don't need XcodeGen installed, but that pbxproj goes
# stale the moment project.yml or the source tree changes (new files,
# new resources, new build phases, new preBuildScripts). Without this
# step, a contributor who adds a new .swift file under the project's
# source root sees CI fail with "cannot find <Type> in scope" — the
# file is on disk but missing from the pbxproj.
#
# Runs after `actions/checkout` and `select_xcode`, before
# `configure_xcode_signing.sh` and `build_xcode.sh`. Safe to run on
# every job: idempotent against an already-up-to-date project.

set -euo pipefail

if [ ! -f project.yml ]; then
    echo "No project.yml at repo root — using committed .xcodeproj as-is"
    exit 0
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Installing xcodegen via Homebrew"
    brew install xcodegen
fi

echo "::group::xcodegen generate"
xcodegen generate
echo "::endgroup::"
echo "Regenerated .xcodeproj from project.yml"
