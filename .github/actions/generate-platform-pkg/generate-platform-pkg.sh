#!/usr/bin/env bash
set -euo pipefail

# Generate platform-specific package.json for npm
# Usage: generate-platform-pkg.sh <binary-name> <platform> <npm-package-name> <release-tag> <license> <os> <cpu>
# Example: generate-platform-pkg.sh myapp linux-x64 @scope/myapp v1.0.0 MIT linux x64

BINARY_NAME="$1"
PLATFORM="$2"
NPM_PACKAGE_NAME="$3"
RELEASE_TAG="$4"
LICENSE="$5"
PLATFORM_OS="$6"
PLATFORM_CPU="$7"

SCOPE=$(echo "$NPM_PACKAGE_NAME" | grep -oE '^@[^/]+' || echo "")
VERSION="${RELEASE_TAG#v}"

# Build package name: scoped (@scope/binary-platform) or unscoped (binary-platform)
if [[ -n "$SCOPE" ]]; then
  PKG_NAME="${SCOPE}/${BINARY_NAME}-${PLATFORM}"
else
  PKG_NAME="${BINARY_NAME}-${PLATFORM}"
fi

cat > "platforms/${BINARY_NAME}-${PLATFORM}/package.json" << EOF
{
  "name": "${PKG_NAME}",
  "version": "$VERSION",
  "os": ["$PLATFORM_OS"],
  "cpu": ["$PLATFORM_CPU"],
  "type": "module",
  "files": ["${BINARY_NAME}*"],
  "license": "$LICENSE"
}
EOF

echo "✓ Generated package.json for ${BINARY_NAME}-${PLATFORM}"
