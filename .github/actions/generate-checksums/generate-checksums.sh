#!/usr/bin/env bash
set -euo pipefail

# Generate checksums manifest for release artifacts
# Usage: generate-checksums.sh <artifacts-dir> <output-file> [--upload-to-release <tag>]
# Example: generate-checksums.sh dist/bin checksums.txt
# Example: generate-checksums.sh dist/bin checksums.txt --upload-to-release v1.0.0

ARTIFACTS_DIR="$1"
OUTPUT_FILE="$2"
UPLOAD_FLAG="${3:-}"
RELEASE_TAG="${4:-}"

if [[ ! -d "$ARTIFACTS_DIR" ]]; then
  echo "::error::Artifacts directory not found: $ARTIFACTS_DIR"
  exit 1
fi

echo "Generating checksums for files in $ARTIFACTS_DIR"
echo ""

# Create checksums file
{
  echo "# SHA256 Checksums"
  echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo ""

  for file in "$ARTIFACTS_DIR"/*; do
    if [[ -f "$file" ]]; then
      filename=$(basename "$file")
      hash=$(sha256sum "$file" | awk '{print $1}')
      size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file")
      echo "$hash  $filename"
      echo "  Size: $size bytes" >&2
    fi
  done
} > "$OUTPUT_FILE"

echo ""
echo "Checksums written to: $OUTPUT_FILE"
cat "$OUTPUT_FILE"

# Upload to release if requested
if [[ "$UPLOAD_FLAG" == "--upload-to-release" && -n "$RELEASE_TAG" ]]; then
  echo ""
  echo "Uploading checksums to release: $RELEASE_TAG"
  gh release upload "$RELEASE_TAG" "$OUTPUT_FILE" --clobber
  echo "✓ Uploaded checksums to release"
fi

echo ""
echo "✓ Checksums generated successfully"
