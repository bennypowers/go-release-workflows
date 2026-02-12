#!/usr/bin/env bash
set -euo pipefail

# Download binary from GitHub release
# Usage: download-binary.sh <binary-name> <platform> <release-tag>
# Example: download-binary.sh myapp linux-x64 v1.0.0

BINARY_NAME="$1"
PLATFORM="$2"
RELEASE_TAG="$3"

PLATFORM_DIR="platforms/${BINARY_NAME}-${PLATFORM}"
mkdir -p "$PLATFORM_DIR"

EXT=""
[[ "$PLATFORM" == win32-* ]] && EXT=".exe"

gh release download "$RELEASE_TAG" \
  --pattern "${BINARY_NAME}-${PLATFORM}${EXT}" \
  --dir "$PLATFORM_DIR"

# Rename to just the binary name; platform info is in the package name
mv "$PLATFORM_DIR/${BINARY_NAME}-${PLATFORM}${EXT}" "$PLATFORM_DIR/${BINARY_NAME}${EXT}"

# Ensure execute permission survives npm pack/install.
# gh release download produces 644 since HTTP has no permission metadata.
[[ -z "$EXT" ]] && chmod +x "$PLATFORM_DIR/${BINARY_NAME}"
