#!/usr/bin/env bash
set -euo pipefail

# Detect repository license via GitHub API
# Usage: detect-license.sh <repository> [explicit-license]
# Example: detect-license.sh owner/repo
# Example: detect-license.sh owner/repo MIT
# Output: License SPDX ID written to $GITHUB_OUTPUT

REPOSITORY="$1"
EXPLICIT_LICENSE="${2:-}"

if [[ -n "$EXPLICIT_LICENSE" ]]; then
  echo "license=$EXPLICIT_LICENSE" >> "$GITHUB_OUTPUT"
else
  LICENSE=$(gh api "repos/$REPOSITORY" --jq '.license.spdx_id // "MIT"')
  echo "license=$LICENSE" >> "$GITHUB_OUTPUT"
fi
