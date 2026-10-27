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

# The package's own license wins, including a differently named one. Staging a
# second file would ship two licenses in one tarball, which reads as ambiguous
# about which one applies.
EXISTING_NAME=""
EXISTING_PATH=""
while IFS= read -r path; do
  base=$(basename "$path")
  case "$base" in
    LICENSE | LICENSE.* | LICENCE | LICENCE.* | COPYING | COPYING.* | \
      license | license.* | licence | licence.* | copying | copying.*)
      # Skip empty files: shipping one would be worse than staging ours.
      [[ -s "$path" ]] || continue
      EXISTING_NAME="$base"
      EXISTING_PATH="$path"
      break
      ;;
  esac
done < <(find "$NPM_DIR" -mindepth 1 -maxdepth 1 ! -type d ! -name '.*' | sort)

if [[ -n "$EXISTING_NAME" ]]; then
  LICENSE_NAME="$EXISTING_NAME"
  if [[ -L "$EXISTING_PATH" ]]; then
    # A symlink dangles for consumers of the tarball; replace it with a copy.
    rm -f "$EXISTING_PATH"
    cp "$LICENSE_SRC" "$NPM_DIR/$LICENSE_NAME"
    echo "Replaced symlinked $NPM_DIR/$LICENSE_NAME with a real file" >&2
  else
    echo "License already present in $NPM_DIR: $LICENSE_NAME" >&2
  fi
else
  cp "$LICENSE_SRC" "$NPM_DIR/$LICENSE_NAME"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "license-file=$LICENSE_NAME" >> "$GITHUB_OUTPUT"
fi

echo "✓ Staged ${LICENSE_NAME} in ${NPM_DIR}"
