#!/usr/bin/env bash
set -euo pipefail

# Generate platform-specific package.json for npm.
# Also copies the repository license file into the package, since npm platform
# tarballs must ship their own license (a symlink would dangle for consumers).
#
# Usage: generate-platform-pkg.sh <binary-name> <platform> <npm-package-name> <release-tag> <license> <os> <cpu> <repository> [license-file]
# Example: generate-platform-pkg.sh myapp linux-x64 @scope/myapp v1.0.0 MIT linux x64 owner/repo
# Example: generate-platform-pkg.sh myapp linux-x64 @scope/myapp v1.0.0 MIT linux x64 owner/repo legal/COPYING

BINARY_NAME="$1"
PLATFORM="$2"
NPM_PACKAGE_NAME="$3"
RELEASE_TAG="$4"
LICENSE="$5"
PLATFORM_OS="$6"
PLATFORM_CPU="$7"
REPOSITORY="$8"
LICENSE_FILE="${9:-}"

SCOPE=$(echo "$NPM_PACKAGE_NAME" | grep -oE '^@[^/]+' || echo "")
VERSION="${RELEASE_TAG#v}"

PLATFORM_DIR="platforms/${BINARY_NAME}-${PLATFORM}"
mkdir -p "$PLATFORM_DIR"

# Locate the license file: explicit path wins, otherwise use conventional names.
LICENSE_SRC=""
if [[ -n "$LICENSE_FILE" ]]; then
  if [[ ! -f "$LICENSE_FILE" ]]; then
    echo "::error::License file not found: $LICENSE_FILE" >&2
    exit 1
  fi
  LICENSE_SRC="$LICENSE_FILE"
else
  for candidate in LICENSE* LICENCE* COPYING*; do
    if [[ -f "$candidate" ]]; then
      LICENSE_SRC="$candidate"
      break
    fi
  done
fi

if [[ -z "$LICENSE_SRC" ]]; then
  echo "::error::No license file found in $(pwd); platform packages must include one (set the license-file input or add LICENSE to the repository)" >&2
  exit 1
fi

LICENSE_NAME=$(basename "$LICENSE_SRC")

# Real copy, not a symlink: the tarball must remain self-contained.
cp "$LICENSE_SRC" "$PLATFORM_DIR/$LICENSE_NAME"

# Build package name: scoped (@scope/binary-platform) or unscoped (binary-platform)
if [[ -n "$SCOPE" ]]; then
  PKG_NAME="${SCOPE}/${BINARY_NAME}-${PLATFORM}"
else
  PKG_NAME="${BINARY_NAME}-${PLATFORM}"
fi

cat > "$PLATFORM_DIR/package.json" << EOF
{
  "name": "${PKG_NAME}",
  "version": "$VERSION",
  "os": ["$PLATFORM_OS"],
  "cpu": ["$PLATFORM_CPU"],
  "type": "module",
  "files": ["${BINARY_NAME}*", "${LICENSE_NAME}"],
  "license": "$LICENSE",
  "repository": {
    "type": "git",
    "url": "https://github.com/${REPOSITORY}"
  }
}
EOF

echo "✓ Generated package.json and copied ${LICENSE_NAME} for ${BINARY_NAME}-${PLATFORM}"
