#!/usr/bin/env bash
# Runs gdformat (formatting) + gdlint (style) across the project.
# gdtoolkit is installed into a per-runner cache via uv to avoid PEP 668
# externally-managed issues on Debian/Ubuntu.
#
# Env:
#   LINT_DIRS  — space-separated dirs to lint (default: "scripts tools test")

set -euo pipefail

LINT_DIRS="${LINT_DIRS:-scripts tools test}"
CACHE_DIR="${RUNNER_TOOL_CACHE:-$HOME/.cache}/gdtoolkit"
mkdir -p "$CACHE_DIR"

UV_BIN="$CACHE_DIR/uv"
if [ ! -x "$UV_BIN" ]; then
	echo "Installing uv into $CACHE_DIR"
	curl -fsSL https://astral.sh/uv/install.sh | UV_INSTALL_DIR="$CACHE_DIR" sh >/dev/null
fi

export UV_TOOL_BIN_DIR="$CACHE_DIR/bin"
export UV_TOOL_DIR="$CACHE_DIR/tools"
mkdir -p "$UV_TOOL_BIN_DIR" "$UV_TOOL_DIR"
PATH="$UV_TOOL_BIN_DIR:$PATH"

if ! command -v gdformat >/dev/null 2>&1; then
	echo "Installing gdtoolkit into $UV_TOOL_DIR"
	"$UV_BIN" tool install --quiet "gdtoolkit>=4.3,<5"
fi

GDFORMAT="$(command -v gdformat)"
GDLINT="$(command -v gdlint)"

# shellcheck disable=SC2086
echo "::group::gdformat (check)"
"$GDFORMAT" --check $LINT_DIRS 2>&1 | tee /tmp/gdformat.out
gdformat_status=${PIPESTATUS[0]}
echo "::endgroup::"

# shellcheck disable=SC2086
echo "::group::gdlint"
"$GDLINT" $LINT_DIRS 2>&1 | tee /tmp/gdlint.out
gdlint_status=${PIPESTATUS[0]}
echo "::endgroup::"

if [ "$gdformat_status" -ne 0 ] || [ "$gdlint_status" -ne 0 ]; then
	echo
	echo "Lint failed. Run \`gdformat $LINT_DIRS\` locally to auto-fix formatting."
	exit 1
fi
