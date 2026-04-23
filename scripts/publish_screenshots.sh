#!/usr/bin/env bash
# Publishes PNGs under $SCREENSHOT_DIR three ways:
#
#   1. Writes a rendered `index.md` next to the PNGs on the orphan
#      `ci-screenshots` branch. github.com's blob viewer is on an
#      authenticated page for the same private repo, so <img> tags
#      render inline there. This is the primary viewing surface and
#      the URL is permanent (lives as long as the branch).
#
#   2. Also writes the same gallery to $GITHUB_STEP_SUMMARY. Cheap
#      and handy while the run is still visible in Actions.
#
#   3. Posts / updates a single short PR comment linking to the
#      index.md blob plus per-image click-through URLs.
#
# We don't put images in the PR comment itself because GitHub doesn't
# rewrite raw / github.com-raw URLs into authenticated camo proxies
# inside comments on private repos — <img> tags there 404 silently.
#
# Required env:
#   GITHUB_TOKEN        — workflow token (contents+PR write)
#   GITHUB_REPOSITORY   — owner/repo
#   GITHUB_SERVER_URL   — https://github.com (provided by Actions)
#   PR_NUMBER           — pull request number
#   COMMIT_SHA          — head commit sha of the PR
#   SCREENSHOT_DIR      — local dir with <device>/<scene>.png
#   BRANCH              — optional, defaults to ci-screenshots
#   GITHUB_STEP_SUMMARY — provided by Actions; gallery goes here too

set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_NUMBER:?PR_NUMBER required}"
: "${COMMIT_SHA:?COMMIT_SHA required}"
: "${SCREENSHOT_DIR:?SCREENSHOT_DIR required}"

BRANCH="${BRANCH:-ci-screenshots}"
MARKER="<!-- ci-screenshots -->"
SHORT_SHA="${COMMIT_SHA:0:7}"
REL_PATH="pr-${PR_NUMBER}/${SHORT_SHA}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

if [ ! -d "$SCREENSHOT_DIR" ] || [ -z "$(ls -A "$SCREENSHOT_DIR")" ]; then
	echo "No screenshots in $SCREENSHOT_DIR — nothing to publish" >&2
	exit 0
fi

# --- Enumerate (device, scene) --------------------------------------
devices=()
while IFS= read -r d; do
	devices+=("$(basename "$d")")
done < <(find "$SCREENSHOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

scenes=()
if [ "${#devices[@]}" -gt 0 ]; then
	while IFS= read -r s; do
		scenes+=("$(basename "$s" .png)")
	done < <(find "$SCREENSHOT_DIR/${devices[0]}" -maxdepth 1 -name '*.png' | sort)
fi

# Paths on the orphan branch, once the PNGs land there. raw URLs are
# used as <img src=> targets because GitHub's blob-viewer markdown
# renderer proxies them through camo on an authenticated page, which
# works for private repos. <a href=> targets are /blob/ so click-
# through opens the image viewer rather than a raw-content 404.
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${BRANCH}/${REL_PATH}"
BLOB_BASE="${SERVER_URL}/${GITHUB_REPOSITORY}/blob/${BRANCH}/${REL_PATH}"
INDEX_URL="${BLOB_BASE}/index.md"

# --- Build the gallery markdown (shared by index.md + step summary) --
GALLERY_FILE="$(mktemp)"
{
	echo "# Device screenshots — \`${SHORT_SHA}\`"
	echo
	echo "PR [#${PR_NUMBER}](${SERVER_URL}/${GITHUB_REPOSITORY}/pull/${PR_NUMBER})"
	echo
	echo "<table>"
	printf "<tr><th></th>"
	for d in "${devices[@]}"; do
		pretty="${d//_/ }"
		printf "<th>%s</th>" "$pretty"
	done
	printf "</tr>\n"
	for s in "${scenes[@]}"; do
		printf "<tr><th>%s</th>" "$s"
		for d in "${devices[@]}"; do
			# src= is a sibling path relative to index.md so the blob
			# viewer resolves without needing the full raw URL. The
			# step-summary copy below uses absolute URLs.
			printf '<td><a href="./%s/%s.png"><img src="./%s/%s.png" width="220"></a></td>' \
				"$d" "$s" "$d" "$s"
		done
		printf "</tr>\n"
	done
	echo "</table>"
} > "$GALLERY_FILE"

# --- Push PNGs + index.md to the orphan branch ------------------------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR" "$GALLERY_FILE"' EXIT

REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

git -C "$WORK_DIR" init -q
git -C "$WORK_DIR" remote add origin "$REMOTE"
git -C "$WORK_DIR" config user.email "ci-screenshots@users.noreply.github.com"
git -C "$WORK_DIR" config user.name "ci-screenshots"

if git -C "$WORK_DIR" fetch --depth=1 origin "$BRANCH" 2>/dev/null; then
	git -C "$WORK_DIR" checkout -q "$BRANCH"
else
	echo "Creating orphan branch $BRANCH"
	git -C "$WORK_DIR" checkout -q --orphan "$BRANCH"
	git -C "$WORK_DIR" rm -rf . >/dev/null 2>&1 || true
fi

TARGET="$WORK_DIR/$REL_PATH"
mkdir -p "$TARGET"
cp -r "$SCREENSHOT_DIR"/* "$TARGET/"
cp "$GALLERY_FILE" "$TARGET/index.md"

git -C "$WORK_DIR" add "$REL_PATH"
if git -C "$WORK_DIR" diff --cached --quiet; then
	echo "No new screenshots to push"
else
	git -C "$WORK_DIR" commit -q -m "PR #${PR_NUMBER} @ ${SHORT_SHA}"
	# Retry with backoff on transient network failures.
	attempt=1
	delay=2
	until git -C "$WORK_DIR" push -q origin "$BRANCH"; do
		if [ "$attempt" -ge 4 ]; then
			echo "git push failed after $attempt attempts" >&2
			exit 1
		fi
		echo "push failed, retrying in ${delay}s…" >&2
		sleep "$delay"
		attempt=$((attempt + 1))
		delay=$((delay * 2))
	done
fi

# --- Also append to the job step summary ------------------------------
# The step summary uses absolute raw.githubusercontent.com URLs since
# it isn't in a markdown file's directory context.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "## Device screenshots — \`${SHORT_SHA}\`"
		echo
		echo "Permanent link: [${INDEX_URL}](${INDEX_URL})"
		echo
		echo "<table>"
		printf "<tr><th></th>"
		for d in "${devices[@]}"; do
			pretty="${d//_/ }"
			printf "<th>%s</th>" "$pretty"
		done
		printf "</tr>\n"
		for s in "${scenes[@]}"; do
			printf "<tr><th>%s</th>" "$s"
			for d in "${devices[@]}"; do
				printf '<td><a href="%s/%s/%s.png"><img src="%s/%s/%s.png" width="220"></a></td>' \
					"$BLOB_BASE" "$d" "$s" "$RAW_BASE" "$d" "$s"
			done
			printf "</tr>\n"
		done
		echo "</table>"
	} >> "$GITHUB_STEP_SUMMARY"
fi

# --- Build the short PR comment ---------------------------------------
BODY_FILE="$(mktemp)"
{
	echo "$MARKER"
	echo "### 📸 CI screenshots — \`${SHORT_SHA}\`"
	echo
	echo "Inline gallery (images render on github.com's authenticated blob viewer):"
	echo
	echo "**[→ Open screenshot gallery](${INDEX_URL})**"
	echo
	echo "Per-image click-through:"
	echo
	for s in "${scenes[@]}"; do
		printf -- "- **%s** · " "$s"
		sep=""
		for d in "${devices[@]}"; do
			pretty="${d//_/ }"
			printf "%s[%s](%s/%s/%s.png)" "$sep" "$pretty" "$BLOB_BASE" "$d" "$s"
			sep=" · "
		done
		printf "\n"
	done
} > "$BODY_FILE"

# --- Post or update the PR comment ------------------------------------
API="https://api.github.com/repos/${GITHUB_REPOSITORY}"
AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json")

existing_id="$(
	curl -sS "${AUTH[@]}" "${API}/issues/${PR_NUMBER}/comments?per_page=100" \
	| MARKER="$MARKER" python3 -c "
import json, os, sys
marker = os.environ['MARKER']
for c in json.load(sys.stdin):
    if c.get('body', '').startswith(marker):
        print(c['id'])
        break
"
)"

payload="$(python3 -c "
import json, sys
print(json.dumps({'body': sys.stdin.read()}))
" < "$BODY_FILE")"

if [ -n "$existing_id" ]; then
	echo "Updating existing comment $existing_id"
	curl -sS -X PATCH "${AUTH[@]}" \
		-d "$payload" \
		"${API}/issues/comments/${existing_id}" >/dev/null
else
	echo "Posting new comment on PR #${PR_NUMBER}"
	curl -sS -X POST "${AUTH[@]}" \
		-d "$payload" \
		"${API}/issues/${PR_NUMBER}/comments" >/dev/null
fi

echo "Screenshots published → $INDEX_URL"
