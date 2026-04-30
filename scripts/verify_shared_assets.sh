#!/usr/bin/env bash
set -euo pipefail

# Verifies that this game repo's fonts/ directory matches the reference
# checksums in pipeline-core. Skipped automatically for projects that don't
# have a fonts/ directory (e.g. OtherGame uses Assets/Fonts/).
#
# To update the reference after a font change, see the header comment in
# pipeline-core/shared-asset-checksums.txt.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKSUMS="$SCRIPT_DIR/../shared-asset-checksums.txt"

if [[ ! -d fonts ]]; then
  echo "No fonts/ directory — skipping shared-asset check."
  exit 0
fi

echo "Verifying fonts/ against pipeline-core reference checksums..."
if md5sum --check "$CHECKSUMS" --quiet; then
  echo "All shared font assets match."
else
  echo ""
  echo "ERROR: One or more font files have drifted from the shared reference."
  echo "Either propagate the updated fonts to all three consumer repos and update"
  echo "pipeline-core/shared-asset-checksums.txt, or revert the local change."
  exit 1
fi
