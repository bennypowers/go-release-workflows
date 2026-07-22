#!/usr/bin/env bash
set -euo pipefail

# Publish npm package with idempotency (skip if already published)
# Usage: npm-publish.sh [working-directory]
# Example: npm-publish.sh platforms/myapp-linux-x64
# Example: npm-publish.sh npm

WORKING_DIR="${1:-.}"

cd "$WORKING_DIR"

PROVENANCE_FLAG=""
if [[ "${NPM_PROVENANCE:-false}" == "true" ]]; then
  PROVENANCE_FLAG="--provenance"
  if [[ -z "${NODE_AUTH_TOKEN:-}" ]]; then
    sed -i '/_authToken/d' "$HOME/.npmrc" 2>/dev/null || true
  fi
fi

npm_output=$(mktemp)
set +e
npm publish --access public $PROVENANCE_FLAG > "$npm_output" 2>&1
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
