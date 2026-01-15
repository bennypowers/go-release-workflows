#!/usr/bin/env bash
set -euo pipefail

# Publish npm package with idempotency (skip if already published)
# Usage: npm-publish.sh [working-directory]
# Example: npm-publish.sh platforms/myapp-linux-x64
# Example: npm-publish.sh npm

WORKING_DIR="${1:-.}"

cd "$WORKING_DIR"

npm_output=$(mktemp)
set +e
npm publish --access public > "$npm_output" 2>&1
exit_code=$?
set -e
cat "$npm_output"

if [[ $exit_code -eq 0 ]]; then
  echo "✓ Published package"
elif grep -qE 'cannot publish over the previously published' "$npm_output"; then
  echo "::warning::Package already published (skipping)"
else
  rm -f "$npm_output"
  exit $exit_code
fi

rm -f "$npm_output"
