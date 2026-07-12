#!/usr/bin/env bash
# Computes the version + build number for the current commit.
#
# Versioning:
#   The latest `v*` tag is the baseline. `major`/`minor` bumps are explicit
#   (BUMP=major|minor, normally from the release workflow's bump picker); a
#   `patch` bump — the default, and what the nightly release uses — adds the
#   number of commits made since that tag.
#
#     baseline v0.2.0 + 3 commits, BUMP=patch  ->  0.2.3
#     baseline v0.2.3,             BUMP=minor  ->  0.3.0
#     baseline v0.2.3,             BUMP=major  ->  1.0.0
#
#   The release workflow tags every release, so the next run's baseline is the
#   tag it just cut: the patch carries forward and keeps climbing.
#
#   build — a unix timestamp. It must be ever-rising per version or App Store
#   Connect rejects the upload. github.run_number is NOT safe here: GitHub does
#   not increment it on a re-run (it bumps run_attempt instead), so a re-run
#   resubmits an already-used build number and the upload is rejected. A
#   timestamp is monotonic and re-run-safe.
#
# Env:
#   BUMP   patch (default) | minor | major
#
# Outputs to GITHUB_OUTPUT (and stdout for local debugging):
#   version=X.Y.Z
#   build=N
#   release=true|false   false when a patch bump finds no new commits — the
#                        caller should skip the build entirely (a quiet night).

set -euo pipefail

BUMP="${BUMP:-patch}"

# Make sure tags are present even on shallow checkouts.
git fetch --tags --force >/dev/null 2>&1 || true

LATEST_TAG="$(git tag -l 'v*' --sort=-v:refname | head -1)"

if [ -z "$LATEST_TAG" ]; then
	# No baseline tag. Deliberately do NOT fall back to counting every commit in
	# the repo — that yields a nonsense patch (0.1.<total commits>) which can
	# outrank a real version. Seed a clean baseline instead.
	VERSION="0.2.0"
	RELEASE="true"
	echo "Latest tag : <none> — seeding baseline"
else
	BASE_VERSION="${LATEST_TAG#v}"
	COMMITS_SINCE="$(git rev-list "${LATEST_TAG}..HEAD" --count)"
	IFS='.' read -r MAJOR MINOR PATCH <<<"$BASE_VERSION"

	case "$BUMP" in
	major)
		VERSION="$((MAJOR + 1)).0.0"
		RELEASE="true"
		;;
	minor)
		VERSION="${MAJOR}.$((MINOR + 1)).0"
		RELEASE="true"
		;;
	patch)
		if [ "$COMMITS_SINCE" -eq 0 ]; then
			# Nothing new since the last release — nothing to ship.
			VERSION="$BASE_VERSION"
			RELEASE="false"
		else
			VERSION="${MAJOR}.${MINOR}.$((PATCH + COMMITS_SINCE))"
			RELEASE="true"
		fi
		;;
	*)
		echo "::error::Unknown BUMP '$BUMP' (expected patch, minor or major)" >&2
		exit 1
		;;
	esac

	echo "Latest tag : $LATEST_TAG"
	echo "Commits sin: $COMMITS_SINCE"
fi

BUILD="$(date -u +%s)"

echo "Bump       : $BUMP"
echo "Version    : $VERSION"
echo "Build      : $BUILD"
echo "Release    : $RELEASE"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "version=$VERSION"
		echo "build=$BUILD"
		echo "release=$RELEASE"
	} >>"$GITHUB_OUTPUT"
fi
