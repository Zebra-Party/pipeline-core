#!/usr/bin/env bash
# Computes the version + build number for the current commit.
#
# Versioning:
#   major.minor — bumped manually by tagging `vX.Y.0` on a commit and
#     pushing the tag. The base patch is always 0 at the tag.
#   patch — auto-bumped by the number of commits since the latest
#     `v*` tag. Tag v0.1.0 + 5 commits since → patch becomes 5.
#   build — github.run_number, which monotonically increases per workflow
#     run regardless of branch. Stores require this to be ever-rising.
#
# Outputs to GITHUB_OUTPUT (and stdout for local debugging):
#   version=X.Y.Z
#   build=N

set -euo pipefail

# Make sure tags are present even on shallow checkouts.
git fetch --tags --force >/dev/null 2>&1 || true

LATEST_TAG="$(git tag -l 'v*' --sort=-v:refname | head -1)"
if [ -z "$LATEST_TAG" ]; then
	BASE_VERSION="0.1.0"
	COMMITS_SINCE="$(git rev-list HEAD --count)"
else
	BASE_VERSION="${LATEST_TAG#v}"
	COMMITS_SINCE="$(git rev-list "${LATEST_TAG}..HEAD" --count)"
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE_VERSION"
NEW_PATCH=$((PATCH + COMMITS_SINCE))
VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"
BUILD="${GITHUB_RUN_NUMBER:-0}"

echo "Latest tag : ${LATEST_TAG:-<none>}"
echo "Commits sin: $COMMITS_SINCE"
echo "Version    : $VERSION"
echo "Build      : $BUILD"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "version=$VERSION"
		echo "build=$BUILD"
	} >> "$GITHUB_OUTPUT"
fi
