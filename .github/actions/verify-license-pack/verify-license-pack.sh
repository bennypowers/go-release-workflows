#!/usr/bin/env bash
set -euo pipefail

# Assert that the license stage-license put in <npm-dir> is in the tarball npm
# would publish. npm auto-includes conventional LICENSE/LICENCE/COPYING names,
# but a custom license-file name only ships when the manifest's files list
# covers it; without this check the wrapper could publish unlicensed.
#
# Shared by the pre-publish preflight and publish-main so the two checks cannot
# drift. It only reads: it never stages or publishes.
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
  echo "::error::could not create a temporary file for npm pack" >&2
  exit 1
}
if ! PACK_JSON=$(cd -- "$NPM_DIR" && npm pack --dry-run --json --ignore-scripts 2>"$errfile"); then
  printf '::error::npm pack failed in %s: %s\n' "$NPM_DIR" "$(cat -- "$errfile")" >&2
  rm -f -- "$errfile"
  exit 1
fi
if [[ -s "$errfile" ]]; then
  printf 'npm pack warning in %s: %s\n' "$NPM_DIR" "$(cat -- "$errfile")" >&2
fi
rm -f -- "$errfile"

if ! PACKED=$(jq -r '.[0].files[]?.path // empty' <<<"$PACK_JSON"); then
  printf '::error::npm pack in %s did not return JSON: %s\n' "$NPM_DIR" "${PACK_JSON:-<empty output>}" >&2
  exit 1
fi

if ! grep -qxF -- "$LICENSE_FILE" <<<"$PACKED"; then
  echo "::error::License file '$LICENSE_FILE' is missing from the main package tarball" >&2
  printf 'Packed files:\n%s\n' "$PACKED" >&2
  exit 1
fi

echo "✓ Main package includes ${LICENSE_FILE}" >&2
