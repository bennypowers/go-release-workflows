#!/usr/bin/env bash
set -euo pipefail

# Validate that the build produced the expected binary
# Usage: validate-output.sh <binary-name> <platform> [--windows]
# Example: validate-output.sh myapp linux-x64
# Example: validate-output.sh myapp win32-x64 --windows

BINARY_NAME="$1"
PLATFORM="$2"
WINDOWS="${3:-}"

if [[ "$WINDOWS" == "--windows" ]]; then
  EXPECTED="dist/bin/${BINARY_NAME}-${PLATFORM}.exe"
else
  EXPECTED="dist/bin/${BINARY_NAME}-${PLATFORM}"
fi

if [[ ! -f "$EXPECTED" ]]; then
  echo "::error::Contract violation: expected '$EXPECTED' but file not found"
  echo ""
  echo "Your 'make $PLATFORM' target must produce:"
  echo "  $EXPECTED"
  exit 1
fi

# Get file size (Linux vs macOS compatible)
if stat -c%s "$EXPECTED" &>/dev/null; then
  SIZE=$(stat -c%s "$EXPECTED")
else
  SIZE=$(stat -f%z "$EXPECTED")
fi

echo "✓ Built: $EXPECTED ($SIZE bytes)"
