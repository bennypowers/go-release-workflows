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

# Keep this candidate list in sync with generate-platform-pkg.sh.
LICENSE_SRC=""
if [[ -n "$LICENSE_FILE" ]]; then
  if [[ ! -f "$LICENSE_FILE" ]]; then
    echo "::error::License file not found: $LICENSE_FILE" >&2
    exit 1
  fi
  if [[ ! -s "$LICENSE_FILE" ]]; then
    echo "::error::License file is empty: $LICENSE_FILE" >&2
    exit 1
  fi
  LICENSE_SRC="$LICENSE_FILE"
else
  for candidate in LICENSE* LICENCE* COPYING* license license.* licence licence.* copying copying.*; do
    if [[ -f "$candidate" && -s "$candidate" ]]; then
      LICENSE_SRC="$candidate"
      break
    fi
  done
fi

if [[ -z "$LICENSE_SRC" ]]; then
  echo "::error::No license file found in $(pwd); the main package must include one (set the license-file input or add LICENSE to the repository)" >&2
  exit 1
fi

LICENSE_NAME=$(basename "$LICENSE_SRC")

# The basename is written to $GITHUB_OUTPUT as a key=value line.
if [[ "$LICENSE_NAME" =~ [[:cntrl:]] ]]; then
  printf '::error::License filename contains control characters: %q\n' "$LICENSE_NAME" >&2
  exit 1
fi

if [[ -f "$NPM_DIR/$LICENSE_NAME" ]]; then
  echo "License already present in $NPM_DIR: $LICENSE_NAME" >&2
else
  cp "$LICENSE_SRC" "$NPM_DIR/$LICENSE_NAME"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "license-file=$LICENSE_NAME" >> "$GITHUB_OUTPUT"
fi

echo "✓ Staged ${LICENSE_NAME} in ${NPM_DIR}"
