#!/usr/bin/env bash
set -euo pipefail

# Stage the repository license into the main npm package directory so the
# published wrapper tarball includes it. A license already present in npm-dir
# wins: the package's own choice is not overwritten.
#
# Usage: stage-license.sh <npm-dir> [license-file]
# Example: stage-license.sh npm
# Example: stage-license.sh npm legal/COPYING
# Output: license-file=<basename> written to $GITHUB_OUTPUT

NPM_DIR="${1:-npm}"
LICENSE_FILE="${2:-}"

if [[ ! -d "$NPM_DIR" ]]; then
  echo "::error::npm directory not found: $NPM_DIR" >&2
  exit 1
fi

# Locate the license file: explicit path wins, otherwise exactly one
# conventional name must exist. Ambiguous candidates are an error.
# shellcheck source=.github/actions/lib/license.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/license.sh"
discover_license_file "$LICENSE_FILE" "the main package"

if [[ -f "$NPM_DIR/$LICENSE_NAME" ]]; then
  echo "License already present in $NPM_DIR: $LICENSE_NAME" >&2
else
  cp "$LICENSE_SRC" "$NPM_DIR/$LICENSE_NAME"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "license-file=$LICENSE_NAME" >> "$GITHUB_OUTPUT"
fi

echo "✓ Staged ${LICENSE_NAME} in ${NPM_DIR}"
