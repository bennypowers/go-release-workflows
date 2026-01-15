#!/usr/bin/env bash
set -euo pipefail

# Collect artifact info as JSON for workflow output
# Usage: collect-artifacts.sh <platforms-json> <binary-name>
# Example: collect-artifacts.sh '["linux-x64", "win32-arm64"]' myapp
# Output: JSON array written to $GITHUB_OUTPUT

PLATFORMS="$1"
BINARY_NAME="$2"

ARTIFACTS="[]"

for platform in $(echo "$PLATFORMS" | jq -r '.[]'); do
  EXT=""
  [[ "$platform" == win32-* ]] && EXT=".exe"

  ARTIFACTS=$(echo "$ARTIFACTS" | jq -c \
    --arg p "$platform" \
    --arg n "${BINARY_NAME}-$platform" \
    --arg f "dist/bin/${BINARY_NAME}-$platform$EXT" \
    '. += [{"platform": $p, "artifact-name": $n, "path": $f}]')
done

echo "artifacts=$ARTIFACTS" >> "$GITHUB_OUTPUT"
