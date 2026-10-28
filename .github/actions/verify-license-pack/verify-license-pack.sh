#!/usr/bin/env bash
set -euo pipefail

# Assert that the license stage-license put in <npm-dir> is in the tarball npm
# would publish. npm auto-includes conventional LICENSE/LICENCE/COPYING names,
# but a custom license-file name only ships when the manifest's files list
# covers it; without this check the wrapper could publish unlicensed.
#
# The check uses `npm publish --dry-run`, not `npm pack --dry-run`: publish also
# runs prepublishOnly, and prepack/prepare can delete or replace the staged
# license. Those scripts run here, exactly as they will during the real
# publish, so the packlist reflects the tarball that would actually ship. They
# can mutate the working tree; callers that care must run this in a throwaway
# checkout. It never stages or publishes.
#
# Usage: verify-license-pack.sh <npm-dir> <license-file>
# Example: verify-license-pack.sh npm LICENSE

NPM_DIR="${1:-npm}"
LICENSE_FILE="${2:-}"

if [[ -z "$LICENSE_FILE" ]]; then
  echo "::error::stage-license did not report a license file" >&2
  exit 1
fi

if [[ ! -d "$NPM_DIR" ]]; then
  echo "::error::npm directory not found: $NPM_DIR" >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "::error::npm is required to verify the package tarball" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required to read npm's packlist" >&2
  exit 1
fi

errfile=$(mktemp "${TMPDIR:-/tmp}/verify-license-pack.XXXXXX") || {
  echo "::error::could not create a temporary file for npm publish" >&2
  exit 1
}
if ! PUBLISH_OUT=$(cd -- "$NPM_DIR" && npm publish --dry-run --json 2>"$errfile"); then
  printf '::error::npm publish --dry-run failed in %s: %s\n' "$NPM_DIR" "$(cat -- "$errfile")" >&2
  rm -f -- "$errfile"
  exit 1
fi
rm -f -- "$errfile"

# Lifecycle scripts may write to stdout before npm emits its JSON. npm's root
# JSON value is a line that is only an opening bracket; nested objects also
# look like that, so take the first one (script output precedes the JSON).
# A script that prints a lone bracket of its own makes jq fail below, which
# reports an error instead of guessing a packlist.
json_start=$(printf '%s\n' "$PUBLISH_OUT" |
  awk '/^[[:space:]]*[\[{][[:space:]]*$/ { print NR; exit }')
if [[ -z "$json_start" ]]; then
  json_start=$(printf '%s\n' "$PUBLISH_OUT" |
    awk '/^[[:space:]]*[\[{]/ { print NR; exit }')
fi
if [[ -z "$json_start" ]]; then
  printf '::error::npm publish --dry-run in %s did not return JSON: %s\n' "$NPM_DIR" "${PUBLISH_OUT:-<empty output>}" >&2
  exit 1
fi
PUBLISH_JSON=$(printf '%s\n' "$PUBLISH_OUT" | tail -n +"$json_start")

# npm publish --json keys the result by package name; npm pack --json returns
# an array. .[] covers both.
if ! PACKED=$(jq -r '.[] | .files[]?.path // empty' <<<"$PUBLISH_JSON"); then
  printf '::error::npm publish --dry-run in %s did not return usable JSON: %s\n' "$NPM_DIR" "$PUBLISH_JSON" >&2
  exit 1
fi

if ! grep -qxF -- "$LICENSE_FILE" <<<"$PACKED"; then
  echo "::error::License file '$LICENSE_FILE' is missing from the main package tarball" >&2
  printf 'Packed files:\n%s\n' "$PACKED" >&2
  exit 1
fi

echo "✓ Main package includes ${LICENSE_FILE}" >&2
