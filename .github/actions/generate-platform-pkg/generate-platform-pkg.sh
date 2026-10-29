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

VERSION="${RELEASE_TAG#v}"

PLATFORM_DIR="platforms/${BINARY_NAME}-${PLATFORM}"
mkdir -p -- "$PLATFORM_DIR"

# Locate the license file: explicit path wins, otherwise exactly one
# conventional name must exist. Ambiguous candidates are an error.
# shellcheck source=.github/actions/lib/license.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/license.sh"
discover_license_file "$LICENSE_FILE" "platform packages"

# Real copy, not a symlink: the tarball must remain self-contained.
cp -- "$LICENSE_SRC" "$PLATFORM_DIR/$LICENSE_NAME"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "license-file=$LICENSE_NAME" >> "$GITHUB_OUTPUT"
fi

# Platform packages are companions to the main npm package, so their names
# derive from npm-package-name, not from the binary name. This matters when the
# two differ: a binary named rhds-mcp published as @rhds/mcp must yield
# @rhds/mcp-linux-x64 so the wrapper's optionalDependencies resolve.
PKG_NAME="${NPM_PACKAGE_NAME}-${PLATFORM}"

# jq escapes all values so package.json stays valid for any input.
jq -n \
  --arg name "$PKG_NAME" \
  --arg version "$VERSION" \
  --arg os "$PLATFORM_OS" \
  --arg cpu "$PLATFORM_CPU" \
  --arg binary_glob "${BINARY_NAME}*" \
  --arg license_file "$LICENSE_NAME" \
  --arg license "$LICENSE" \
  --arg repository_url "https://github.com/${REPOSITORY}" \
  '{
    name: $name,
    version: $version,
    os: [$os],
    cpu: [$cpu],
    type: "module",
    files: [$binary_glob, $license_file],
    license: $license,
    repository: {
      type: "git",
      url: $repository_url
    }
  }' > "$PLATFORM_DIR/package.json"

echo "✓ Generated package.json and copied ${LICENSE_NAME} for ${BINARY_NAME}-${PLATFORM}"
