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
# Empty files are rejected: a zero-byte license is not a license.
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
  for candidate in LICENSE* LICENCE* COPYING*; do
    if [[ -f "$candidate" && -s "$candidate" ]]; then
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

# The basename is written to $GITHUB_OUTPUT as a key=value line, so control
# characters (notably newlines) would corrupt the output file.
if [[ "$LICENSE_NAME" =~ [[:cntrl:]] ]]; then
  printf '::error::License filename contains control characters: %q\n' "$LICENSE_NAME" >&2
  exit 1
fi

# Real copy, not a symlink: the tarball must remain self-contained.
cp "$LICENSE_SRC" "$PLATFORM_DIR/$LICENSE_NAME"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "license-file=$LICENSE_NAME" >> "$GITHUB_OUTPUT"
fi

# Build package name: scoped (@scope/binary-platform) or unscoped (binary-platform)
if [[ -n "$SCOPE" ]]; then
  PKG_NAME="${SCOPE}/${BINARY_NAME}-${PLATFORM}"
else
  PKG_NAME="${BINARY_NAME}-${PLATFORM}"
fi

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
