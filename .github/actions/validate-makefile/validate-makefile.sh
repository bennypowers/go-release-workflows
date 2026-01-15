#!/usr/bin/env bash
set -euo pipefail

# Validate that Makefile has required targets for all requested platforms
# Usage: validate-makefile.sh <platforms-json> <binary-name>
# Example: validate-makefile.sh '["linux-x64", "darwin-arm64"]' myapp

PLATFORMS="$1"
BINARY_NAME="$2"

MISSING=()

for platform in $(echo "$PLATFORMS" | jq -r '.[]'); do
  if ! make -n "$platform" &>/dev/null 2>&1; then
    MISSING+=("$platform")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "::error::Makefile contract violation: missing targets: ${MISSING[*]}"
  echo ""
  echo "Your Makefile must include these targets:"
  for p in "${MISSING[@]}"; do
    echo "  $p:"
    echo "      # build logic producing dist/bin/${BINARY_NAME}-$p"
  done
  echo ""
  echo "See: https://github.com/bennypowers/go-release-workflows#makefile-contract"
  exit 1
fi

echo "✓ All required Makefile targets present"
