#!/usr/bin/env bash
set -euo pipefail

# Publish npm package with idempotency (skip if already published)
# Usage: npm-publish.sh [working-directory]
# Example: npm-publish.sh platforms/myapp-linux-x64
# Example: npm-publish.sh npm

WORKING_DIR="${1:-.}"

cd "$WORKING_DIR"

npm_args=(publish --access public)
if [[ "${NPM_PROVENANCE:-false}" == "true" ]]; then
  npm_args+=(--provenance)
  # npm swallows OIDC exchange failures and falls back to a generic ENEEDAUTH
  # error, so surface the token-exchange request when publishing with OIDC.
  # npm redacts token values from these logs.
  export npm_config_loglevel="${npm_config_loglevel:-http}"
  if [[ -z "${NODE_AUTH_TOKEN:-}" ]]; then
    # actions/setup-node@v6 writes its npmrc to RUNNER_TEMP and points
    # NPM_CONFIG_USERCONFIG at it, not at $HOME/.npmrc.
    NPMRC="${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}"
    sed -i '/_authToken/d' "$NPMRC" 2>/dev/null || true
  fi
fi

npm_output=$(mktemp)
set +e
npm "${npm_args[@]}" > "$npm_output" 2>&1
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
