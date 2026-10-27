#!/usr/bin/env bash
set -euo pipefail

# Stage the repository license into the main npm package directory so the
# published wrapper tarball includes it.
#
# Precedence (shared with license-lint in lib/license.sh):
#   1. an explicit license-file, because the user named that file;
#   2. a license already present in npm-dir, under any conventional name;
#   3. the repository license.
# A license already present wins by default: staging a second, differently
# named file would ship two licenses in one tarball, which reads as ambiguous
# about which one applies. Empty candidates are removed, and more than one
# non-empty candidate is an error rather than a silent sort-order pick.
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

# shellcheck source=.github/actions/lib/license.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/license.sh"

resolve_license "$NPM_DIR" "$LICENSE_FILE" "the main package" || exit 1

if ! stage_resolved_license "$NPM_DIR" "$RESOLVED_LICENSE_NAME" "$RESOLVED_LICENSE_SRC" \
  ${RESOLVED_REMOVE_NAMES[@]+"${RESOLVED_REMOVE_NAMES[@]}"}; then
  exit 1
fi

if [[ "$RESOLVED_FROM_PACKAGE" -eq 1 ]]; then
  if [[ "$RESOLVED_PACKAGE_SYMLINK" -eq 1 ]]; then
    echo "Replaced symlinked $NPM_DIR/$RESOLVED_LICENSE_NAME with a real file" >&2
  else
    echo "License already present in $NPM_DIR: $RESOLVED_LICENSE_NAME" >&2
  fi
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "license-file=$RESOLVED_LICENSE_NAME" >> "$GITHUB_OUTPUT"
fi

# stdout belongs to the action's caller; progress goes to stderr.
echo "✓ Staged ${RESOLVED_LICENSE_NAME} in ${NPM_DIR}" >&2
